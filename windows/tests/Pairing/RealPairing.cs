using System.Net.Http.Json;
using System.Text.Json.Nodes;
using System.Xml.Linq;
using HoverPocket.Assets;
using HoverPocket.Shell.Sync;

internal static class RealPairing
{
 internal static async Task Run(string[] args)
 {
  var aRoot=Path.GetFullPath(args[1]);var bRoot=Path.GetFullPath(args[2]);var helper=Path.GetFullPath(args[3]);
  if(!File.Exists(Path.Combine(aRoot,"isolated-pairing-test")) || !File.Exists(Path.Combine(bRoot,"isolated-pairing-test"))) throw new Exception("isolation marker missing");
  HttpClient Api(string root) {
   var gui=XDocument.Load(Path.Combine(root,"config.xml")).Root!.Element("gui")!;
   var uri=new Uri("http://"+gui.Element("address")!.Value+"/rest/");if(!uri.IsLoopback)throw new Exception("not loopback");
   var client=new HttpClient{BaseAddress=uri,Timeout=TimeSpan.FromSeconds(10)};client.DefaultRequestHeaders.Add("X-API-Key",gui.Element("apikey")!.Value);return client;
  }
  using var aHttp=Api(aRoot);using var bHttp=Api(bRoot);
  using var aStore=new AssetStore(Path.Combine(aRoot,"library"));using var bStore=new AssetStore(Path.Combine(bRoot,"library"));
  using var a=new DevicePairingService(aStore,()=>new(Api(aRoot)),helper,"Fictional Windows A");
  using var b=new DevicePairingService(bStore,()=>new(Api(bRoot)),helper,"Fictional Windows B");
  var source=Path.Combine(aRoot,"fixture.txt");await File.WriteAllTextAsync(source,"Generated isolated HoverPocket pairing fixture");
  var imported=await aStore.ImportAsync(source);
  try {
   await a.Start("invite",null,default);await Until(()=>a.State.Code is not null,a,b);
   await b.Start("join",a.State.Code,default);await Until(()=>a.State.Phase=="peer"&&b.State.Phase=="peer",a,b);
   if((JsonNode.Parse(await aHttp.GetStringAsync("config/folders"))!.AsArray().Count + JsonNode.Parse(await bHttp.GetStringAsync("config/folders"))!.AsArray().Count)!=0) throw new Exception("share before approval");
   await a.Approve(a.State.ApprovalId!,default);await Until(()=>a.State.Phase=="complete"&&b.State.Phase=="complete",a,b);
   var sa=await aStore.GetSyncStatusAsync();var sb=await bStore.GetSyncStatusAsync();if(sa.GroupId!=sb.GroupId||!sa.Enabled||!sb.Enabled)throw new Exception("group mismatch");
   var aId=JsonNode.Parse(await aHttp.GetStringAsync("system/status"))!["myID"]!.GetValue<string>();var bId=JsonNode.Parse(await bHttp.GetStringAsync("system/status"))!["myID"]!.GetValue<string>();
   async Task Connect(HttpClient http,string id,string peerRoot) {
    var device=JsonNode.Parse(await http.GetStringAsync("config/devices/"+id))!;
    var address=XDocument.Load(Path.Combine(peerRoot,"config.xml")).Root!.Element("options")!.Element("listenAddress")!.Value;
    if(!address.StartsWith("tcp://127.0.0.1:"))throw new Exception("nonlocal test transport");
    device["addresses"]=new JsonArray(address);using var response=await http.PutAsJsonAsync("config/devices/"+id,device);response.EnsureSuccessStatusCode();
   }
   await Connect(aHttp,bId,bRoot);await Connect(bHttp,aId,aRoot);
   await aStore.SyncOnceAsync();
   var folder=JsonNode.Parse(await aHttp.GetStringAsync("config/folders"))!.AsArray().Single()!["id"]!.GetValue<string>();
   bool received=false;
   for(int i=0;i<60;i++) {
    using var scanA=await aHttp.PostAsync("db/scan?folder="+folder,null);using var scanB=await bHttp.PostAsync("db/scan?folder="+folder,null);
    await bStore.SyncOnceAsync();if(await bStore.GetAsync(imported.AssetId!) is not null) {received=true;break;}await Task.Delay(1000);
   }
   if(!received)throw new Exception("generated fixture did not synchronize");
   using var link=new SyncthingLibraryLink(Api(aRoot));var plan=await link.Plan(sa,default);await link.Remove(plan,bId,default);
   if((await link.Devices(plan,default)).Length!=0)throw new Exception("peer not removed");
   if(!(JsonNode.Parse(await aHttp.GetStringAsync("config/devices"))!.AsArray().Any(d=>d?["deviceID"]?.GetValue<string>()==bId))) throw new Exception("global device was removed");
   Console.WriteLine("PASS real isolated Syncthing: no preapproval share, both hosts configure/readback, generated original+metadata transfer, scoped removal preserves global device");
  } finally {await a.Cancel(default);await b.Cancel(default);}
 }
 static async Task Until(Func<bool> predicate,DevicePairingService a,DevicePairingService b) {
  for(int i=0;i<600;i++) { if(a.State.Phase=="error"||b.State.Phase=="error") throw new Exception("pairing failed: "+a.State.Error+" / "+b.State.Error); if(predicate())return;await Task.Delay(100); }throw new TimeoutException("pairing timeout");
 }
}
