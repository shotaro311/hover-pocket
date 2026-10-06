using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Xml.Linq;
using HoverPocket.Assets;
using HoverPocket.Shell.Sync;

// Private stdio for a parent cross-OS verifier; never forward this stream to logs.
internal static class CrossPairing
{
    private static readonly object OutputLock = new();
    private static void Emit(object value) { lock(OutputLock) Console.WriteLine(JsonSerializer.Serialize(value)); }
    internal static async Task Run(string configPath)
    {
        var config=JsonNode.Parse(await File.ReadAllTextAsync(configPath))!;
        var root=Path.GetFullPath(config["root"]!.GetValue<string>());
        if(!File.Exists(Path.Combine(root,"isolated-pairing-test"))) throw new IOException("Isolation marker missing");
        var home=Path.Combine(root,"syncthing");
        HttpClient Api() {
            var gui=XDocument.Load(Path.Combine(home,"config.xml")).Root!.Element("gui")!;
            var uri=new Uri("http://"+gui.Element("address")!.Value+"/rest/");
            if(!uri.IsLoopback) throw new IOException("Test API must be loopback");
            var http=new HttpClient{BaseAddress=uri,Timeout=TimeSpan.FromSeconds(10)};
            http.DefaultRequestHeaders.Add("X-API-Key",gui.Element("apikey")!.Value); return http;
        }
        using var store=new AssetStore(Path.Combine(root,"library"));
        using var service=new DevicePairingService(store,()=>new(Api()),config["helper"]!.GetValue<string>(),"Isolated Windows");
        using var deadline=new CancellationTokenSource(TimeSpan.FromMinutes(8));
        var token=deadline.Token;
        var monitor=Task.Run(async()=> {
            PairingState? previous=null;
            while(!token.IsCancellationRequested) {
                var state=service.State;
                if(state!=previous) {
                    previous=state;
                    var kind=state.Phase=="waiting"?"code":state.Phase;
                    Emit(new { @event=kind, code=state.Code, approvalId=state.ApprovalId, verification=state.Verification, peerName=state.PeerName, platform=state.Platform, error=state.Error });
                }
                await Task.Delay(30,token);
            }
        },token);
        Emit(new { @event="ready" });
        try {
            while(await Console.In.ReadLineAsync(token) is { } line) {
                var request=JsonNode.Parse(line)!;
                switch(request["action"]?.GetValue<string>()) {
                    case "start": await service.Start(request["role"]!.GetValue<string>(),request["code"]?.GetValue<string>(),token); break;
                    case "approve": await service.Approve(request["approvalId"]!.GetValue<string>(),token); break;
                    case "cancel": await service.Cancel(token); break;
                    case "connect":
                        var port=request["port"]!.GetValue<int>();
                        if(port is <1 or >65535) throw new IOException("Invalid tunnel port");
                        using(var api=Api()) {
                            using var link=new SyncthingLibraryLink(Api());
                            var plan=await link.Plan(await store.GetSyncStatusAsync(token),token);
                            var peers=JsonNode.Parse(await api.GetStringAsync("config/devices",token))!.AsArray().Where(d=>d?["deviceID"]?.GetValue<string>()!=plan.DeviceId).ToArray();
                            if(peers.Length!=1) throw new IOException("Expected one isolated peer");
                            var peer=peers[0]!; peer["addresses"]=new JsonArray("tcp://127.0.0.1:"+port);
                            using var response=await api.PutAsJsonAsync("config/devices/"+peer["deviceID"]!.GetValue<string>(),peer,token); response.EnsureSuccessStatusCode();
                        }
                        Emit(new { @event="connected" }); break;
                    case "fixture":
                        var source=Path.Combine(root,"generated-fixture.txt");
                        await File.WriteAllTextAsync(source,"Generated cross-OS HoverPocket pairing fixture",token);
                        await store.ImportAsync(source,token:token);
                        Emit(new { @event="fixture" }); break;
                    case "sync":
                        var status=await store.SyncOnceAsync(token);
                        using(var api=Api()) {
                            using var link=new SyncthingLibraryLink(Api()); var plan=await link.Plan(status,token);
                            using var response=await api.PostAsync("db/scan?folder="+Uri.EscapeDataString(plan.FolderId!),null,token); response.EnsureSuccessStatusCode();
                        }
                        var assets=(await store.QueryAsync(new(Limit:100),token)).Items;
                        var valid=assets.All(a=>Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(store.OriginalPath(a)))).Equals(a.Sha256,StringComparison.OrdinalIgnoreCase));
                        Emit(new { @event="synced", groupId=status.GroupId, enabled=status.Enabled, pending=status.Pending, validOriginals=valid, assets=assets.Select(a=>new { a.Id,a.Name,a.Sha256,a.Favorite }) }); break;
                    case "unlink":
                        using(var api=Api()) {
                            using var link=new SyncthingLibraryLink(Api()); var plan=await link.Plan(await store.GetSyncStatusAsync(token),token);
                            var peers=await link.Devices(plan,token);
                            foreach(var peer in peers) await service.Remove(peer.Id,token);
                            if((await link.Devices(plan,token)).Length!=0) throw new IOException("Scoped removal failed");
                            var devices=JsonNode.Parse(await api.GetStringAsync("config/devices",token))!.AsArray();
                            if(peers.Any(peer=>!devices.Any(d=>d?["deviceID"]?.GetValue<string>()==peer.Id))) throw new IOException("Global peer removed");
                        }
                        Emit(new { @event="unlinked" }); break;
                    case "exit": return;
                    default: throw new IOException("Unknown verifier command");
                }
            }
        }
        catch(Exception ex) { Emit(new { @event="error", reason=ex.GetType().Name }); throw; }
        finally {
            await service.Cancel(CancellationToken.None); deadline.Cancel();
            try {await monitor;} catch(OperationCanceledException) { }
        }
    }
}
