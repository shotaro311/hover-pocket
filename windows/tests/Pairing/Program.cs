using System.Net;
using System.Text.Json.Nodes;
using HoverPocket.Shell.Sync;
using HoverPocket.Assets;

if(args.Length>0 && args[0]=="--real") { await RealPairing.Run(args); return; }
int assertions=0;
void Check(bool value, string message) { if(!value) throw new Exception(message); assertions++; }
var handler = new FakeApi();
using var api = new SyncthingLibraryLink(new HttpClient(handler) { BaseAddress = new Uri("http://127.0.0.1:8384/rest/") });
var target=Path.Combine(Path.GetTempPath(),"HoverPocketPairingTest-"+Guid.NewGuid().ToString("N"));
var group=Guid.NewGuid().ToString("D");
var plan=new LinkPlan("SELF", group, "hoverpocket-test",target);
var eagle=handler.Folders[0]!.ToJsonString();
var device=handler.Devices[1]!.ToJsonString();
Check(await api.Add(plan,"PEER","Untrusted rename",default),"add peer");
Check(handler.Folders[0]!.ToJsonString()==eagle,"Eagle unchanged");
Check(handler.Devices[1]!.ToJsonString()==device,"existing device name and flags unchanged");
var folder=handler.Folders[1]!;
Check(folder["custom"]!.GetValue<string>()=="preserve-defaults","folder defaults preserved");
Check(!await api.Add(plan,"PEER","changed",default),"idempotent add");
Check((await api.Devices(plan,default)).Single().Connected,"connection shown");
await api.Remove(plan,"PEER",default);
Check(handler.Folders[1]!["devices"]!.AsArray().Count==1,"only self remains");
Check(handler.Devices.Count==2 && handler.Devices[1]!.ToJsonString()==device,"remove doesn't delete global peer");
Check(handler.Folders[0]!.ToJsonString()==eagle,"remove preserves Eagle");
Check(await api.Add(plan,"NEW","New peer",default),"new peer added");
Check(handler.Devices[2]!["introducer"]!.GetValue<bool>()==false && !handler.Devices[2]!["autoAcceptFolders"]!.GetValue<bool>(),"new peer cannot introduce or auto-accept");
var before=handler.Writes;
try { await api.Add(plan with{Path=target+"-other"},"FOREIGN","Foreign",default); throw new Exception("accepted conflicting folder"); } catch(IOException) { assertions++; }
Check(handler.Writes==before,"collision performs no writes");
try { await api.Add(plan with{FolderId="other-id"},"FOREIGN","Foreign",default); throw new Exception("accepted duplicate path"); } catch(IOException) { assertions++; }
Check(handler.Writes==before,"duplicate path performs no writes");
SyncthingLibraryLink.PrepareMarker(plan);
using(var store=new AssetStore(Path.Combine(target+"-library"))) {
 await store.ConfigureSyncAsync(target); var status=await store.GetSyncStatusAsync();
 Check(status.GroupId==group && !status.Enabled,"marker joins authenticated group without enabling");
 Check((await api.Plan(status,default)).FolderId==plan.FolderId,"existing share discovery");
}
try { SyncthingLibraryLink.PrepareMarker(plan with{GroupId=Guid.NewGuid().ToString("D")}); throw new Exception("replaced group"); } catch(IOException) { assertions++; }
var occupied=target+"-occupied";Directory.CreateDirectory(occupied);await File.WriteAllTextAsync(Path.Combine(occupied,"keep.txt"),"preserve");
try { SyncthingLibraryLink.PrepareMarker(plan with{Path=occupied}); throw new Exception("accepted nonempty directory"); } catch(IOException) { assertions++; }
Check(File.ReadAllText(Path.Combine(occupied,"keep.txt"))=="preserve","foreign files preserved");
Console.WriteLine($"PASS pairing configuration: {assertions} assertions; isolated evidence: {target}");

if (args.Length > 0) {
    var helper=Path.GetFullPath(args[0]);
    foreach(var fail in new[]{false,true}) {
        var aApi=new FakeApi { MyId=string.Join('-',Enumerable.Repeat("AAAAAAA",8)) };
        var bApi=new FakeApi { MyId=string.Join('-',Enumerable.Repeat("BBBBBBB",8)), FailAddFolder=fail };
        using var aStore=new AssetStore(Path.Combine(target,Guid.NewGuid().ToString("N"),"library"));
        using var bStore=new AssetStore(Path.Combine(target,Guid.NewGuid().ToString("N"),"library"));
        using var a=new DevicePairingService(aStore,()=>new(new HttpClient(aApi,false){BaseAddress=new Uri("http://127.0.0.1/rest/")}),helper,"Fictional Windows");
        using var b=new DevicePairingService(bStore,()=>new(new HttpClient(bApi,false){BaseAddress=new Uri("http://127.0.0.1/rest/")}),helper,"Fictional Mac");
        await a.Start("invite",null,default); await Until(()=>a.State.Code is not null);
        await b.Start("join",a.State.Code,default); await Until(()=>a.State.Phase=="peer"&&b.State.Phase=="peer");
        Check(aApi.Writes==0 && bApi.Writes==0,"no Syncthing writes before approval");
        Check(!(await aStore.GetSyncStatusAsync()).Configured && !(await bStore.GetSyncStatusAsync()).Configured,"no library configuration before approval");
        try { await a.Approve("stale",default); throw new Exception("stale approval accepted"); } catch(IOException) { assertions++; }
        Check(aApi.Writes==0,"stale approval writes nothing");
        await a.Approve(a.State.ApprovalId!,default);
        if(!fail) {
            await Until(()=>a.State.Phase=="complete"&&b.State.Phase=="complete");
            Check((await aStore.GetSyncStatusAsync()).GroupId==(await bStore.GetSyncStatusAsync()).GroupId,"both stores join same group");
            Check((await aStore.GetSyncStatusAsync()).Enabled && (await bStore.GetSyncStatusAsync()).Enabled,"both enabled after approval");
            Check(aApi.Folders[0]!.ToJsonString()==eagle && bApi.Folders[0]!.ToJsonString()==eagle,"pairing preserves Eagle on both endpoints");
        } else {
            await Until(()=>a.State.Phase=="error"&&b.State.Phase=="error");
            Check(!aApi.Folders.Any(f=>f?["id"]?.GetValue<string>()!="eagle"&&f?["devices"]?.AsArray().Any(d=>d?["deviceID"]?.GetValue<string>()==bApi.MyId)==true),"peer setup failure removes newly shared peer");
            Check(!(await aStore.GetSyncStatusAsync()).Enabled,"failed pair does not leave sync enabled");
        }
        await a.Cancel(default);await b.Cancel(default);
        Console.WriteLine("PASS native pairing lifecycle: "+(fail?"peer failure rollback":"approval and complete"));
    }
}
Console.WriteLine($"PASS total pairing assertions: {assertions}");
static async Task Until(Func<bool> predicate) {
 for(int i=0;i<600;i++) {if(predicate())return;await Task.Delay(100);} throw new TimeoutException("Pairing phase did not finish");
}

sealed class FakeApi : HttpMessageHandler
{
 internal JsonArray Folders = [new JsonObject { ["id"]="eagle",["path"]="C:/Fictional/Eagle",["type"]="sendreceive",["devices"]=new JsonArray(new JsonObject{["deviceID"]="SELF"},new JsonObject{["deviceID"]="PEER"}),["custom"]="Eagle keep" }];
 internal JsonArray Devices = [new JsonObject{["deviceID"]="SELF",["name"]="Self"},new JsonObject{["deviceID"]="PEER",["name"]="Existing peer",["introducer"]=false,["autoAcceptFolders"]=false,["custom"]="Keep"}];
 internal int Writes;
 internal string MyId="SELF";
 internal bool FailAddFolder;
 protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
 {
  var path=request.RequestUri!.AbsolutePath[6..]; JsonNode? result=null;
  if(request.Method==HttpMethod.Get) result=path switch {
   "system/status" => new JsonObject{["myID"]=MyId},
   "system/connections" => JsonNode.Parse("{\"connections\":{\"PEER\":{\"connected\":true}}}"),
   "config/folders"=>Folders,"config/devices"=>Devices,
   "config/defaults/folder"=>JsonNode.Parse("{\"custom\":\"preserve-defaults\",\"devices\":[]}"),
   "config/defaults/device"=>JsonNode.Parse("{\"introducer\":true,\"autoAcceptFolders\":true}"),
   _ when path.StartsWith("config/folders/") => Folders.FirstOrDefault(f=>f?["id"]?.GetValue<string>()==Uri.UnescapeDataString(path[15..])),
   _ => null };
  else {
   if(FailAddFolder && request.Method==HttpMethod.Post && path=="config/folders") return new(HttpStatusCode.ServiceUnavailable){Content=new StringContent("{}")};
   var node=JsonNode.Parse(await request.Content!.ReadAsStringAsync(token))!;Writes++;
   var collection=path.StartsWith("config/folders")?Folders:Devices;var key=collection==Folders?"id":"deviceID";
   var prior=collection.FirstOrDefault(n=>n?[key]?.GetValue<string>()==node[key]?.GetValue<string>());
   if(prior is not null) collection.Remove(prior); collection.Add(node);result=new JsonObject();
  }
  return new HttpResponseMessage(result is null?HttpStatusCode.NotFound:HttpStatusCode.OK){Content=new StringContent(result?.ToJsonString()??"{}")};
 }
}
