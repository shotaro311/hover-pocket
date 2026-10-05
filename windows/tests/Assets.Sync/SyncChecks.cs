using HoverPocket.Assets;
using Microsoft.Data.Sqlite;
using System.Text.Json;
using System.Security.Cryptography;

internal static class SyncChecks
{
    public static async Task RunAsync()
    {
        var root=Path.Combine(Path.GetTempPath(),"HoverPocketSyncVerify-tests-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root); int count=0;
        void Check(bool ok,string label) { if(!ok) throw new Exception("FAIL "+label); Console.WriteLine("PASS "+label); count++; }
        async Task Reject(Func<Task> action,string label) { try { await action(); } catch(Exception ex) when(ex is InvalidDataException or IOException or InvalidOperationException or ArgumentException) { Check(true,label); return; } throw new Exception("FAIL "+label); }
        async Task Tick(AssetStore s) { var r=await s.SyncOnceAsync(); Check(r.Error is null,"sync without error"); }
        using (var fixtures = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory,"sync-fixtures.json"))))
        {
            var group=fixtures.RootElement.GetProperty("groupId").GetString();
            foreach(var item in fixtures.RootElement.GetProperty("cases").EnumerateArray())
            {
                bool accepted;
                try { accepted=AssetSyncFormat.Parse(System.Text.Encoding.UTF8.GetBytes(item.GetProperty("event").GetRawText())).GroupId==group; }
                catch(Exception ex) when(ex is JsonException or InvalidDataException or ArgumentException) { accepted=false; }
                Check(accepted==item.GetProperty("valid").GetBoolean(),"fixture "+item.GetProperty("name").GetString());
            }
        }
        var transport=Path.Combine(root,"transport");
        using var a=new AssetStore(Path.Combine(root,"a"));
        using var b=new AssetStore(Path.Combine(root,"b"));
        await a.ConfigureSyncAsync(transport,true); await a.SetSyncEnabledAsync(true);
        await b.ConfigureSyncAsync(transport); await b.SetSyncEnabledAsync(true);
        var folder=await a.AddCategoryAsync("folder","資料");
        var child=await a.AddCategoryAsync("folder","写真",folder);
        var tag=await a.AddCategoryAsync("tag","日本語");
        var source=Path.Combine(root,"テスト.txt"); await File.WriteAllTextAsync(source,"日本語の原本 😀");
        var id=(await a.ImportAsync(source,child,true)).AssetId!;
        await a.UpdateAsync([id],"classify",tag); await a.UpdateAsync([id],"favorite");
        await Tick(a); await Tick(b);
        var asset=(await b.GetAsync(id))!;
        Check(asset is { Favorite:true,InternetOrigin:true } && asset.FolderIds.Contains(child) && asset.TagIds.Contains(tag),"addition and all classifications");
        Check((await b.QueryAsync(new())).Folders.Single(f=>f.Id==child).ParentId==folder,"folder hierarchy");
        Check(Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(b.OriginalPath(asset))))==asset.Sha256,"received original hash");
        int Events()=>Directory.GetFiles(Path.Combine(transport,"events"),"*.json",SearchOption.AllDirectories).Length;
        var events=Events(); await Tick(b); await Tick(a); Check(events==Events(),"no echo on repeated receive");
        await b.UpdateAsync([id],"rename","Macで名前変更"); await Tick(b); await Tick(a);
        Check((await a.GetAsync(id))!.Name=="Macで名前変更","reverse rename");
        await a.UpdateAsync([id],"trash"); await Tick(a); await Tick(b); Check((await b.GetAsync(id))!.Trashed,"trash");
        await b.UpdateAsync([id],"restore"); await Tick(b); await Tick(a); Check(!(await a.GetAsync(id))!.Trashed,"restore");
        await a.UpdateAsync([id],"rename","A同時"); await b.UpdateAsync([id],"rename","B同時");
        await Tick(a); await Tick(b); await Tick(a);
        Check((await a.GetAsync(id))!.Name=="A同時" && (await b.GetAsync(id))!.Name=="B同時","conflict keeps local");
        var conflict=(await a.GetSyncStatusAsync()).Conflicts.Single();
        await a.ResolveSyncConflictAsync(conflict.Revision,true); await Tick(b);
        Check((await a.GetAsync(id))!.Name=="B同時" && (await b.GetSyncStatusAsync()).Conflicts.Length==0,"resolve remote");
        await a.UpdateAsync([id],"rename","A選択"); await b.UpdateAsync([id],"rename","B選択");
        await Tick(a); await Tick(b); await Tick(a);
        await a.ResolveSyncConflictAsync((await a.GetSyncStatusAsync()).Conflicts.Single().Revision,false); await Tick(b);
        Check((await b.GetAsync(id))!.Name=="A選択","resolve local");
        await a.SetSyncEnabledAsync(false); await a.UpdateAsync([id],"rename","一時停止中");
        events=Events(); await a.SyncOnceAsync(onlyWhenEnabled:true); Check(Events()==events,"paused has no filesystem exchange");
        await a.SetSyncEnabledAsync(true); await Tick(a); await Tick(b); Check((await b.GetAsync(id))!.Name=="一時停止中","pause resume");
        var marker=Path.Combine(transport,"hoverpocket-sync.json"); File.Move(marker,marker+".held");
        await a.UpdateAsync([id],"rename","切断中"); Check((await a.SyncOnceAsync()).Error is not null,"disconnect stops safely");
        File.Move(marker+".held",marker); await Tick(a); await Tick(b); Check((await b.GetAsync(id))!.Name=="切断中","reconnect");
        await a.UpdateAsync([id],"trash"); await Tick(a); await Tick(b);
        await a.EmptyTrashAsync(path=> { File.Move(path,path+".test-recycled"); return Task.FromResult(true); });
        await Tick(a); await Tick(b); Check(await a.GetAsync(id) is null && (await b.GetAsync(id))!.Trashed && File.Exists(b.OriginalPath(asset)),"physical deletion is local only");
        await b.UpdateAsync([id],"restore"); await Tick(b); await Tick(a); Check(await a.GetAsync(id) is not null,"restore after local purge");
        await a.ChangeCategoryAsync(child,"delete"); await Tick(a); await Tick(b);
        events=Events(); await Tick(b); Check(Events()==events && !(await b.GetAsync(id))!.FolderIds.Contains(child),"category deletion no echo");
        await Reject(()=>a.RestoreDatabaseSnapshotAsync((a.DatabaseSnapshotsAsync().Result).First()),"synced DB rollback rejected");
        var markerText=await File.ReadAllTextAsync(marker);
        await File.WriteAllTextAsync(marker,JsonSerializer.Serialize(new{version=1,groupId=Guid.NewGuid().ToString("D")}));
        Check((await a.SyncOnceAsync()).Error is not null,"foreign marker rejected"); await File.WriteAllTextAsync(marker,markerText);
        var blob=Path.Combine(transport,"blobs",asset.Sha256); var original=await File.ReadAllBytesAsync(blob);
        await File.WriteAllTextAsync(blob,"tampered");
        using var c=new AssetStore(Path.Combine(root,"c")); await c.ConfigureSyncAsync(transport);
        Check((await c.SyncOnceAsync()).Error is not null && await c.GetAsync(id) is null,"tampered original rejected");
        await File.WriteAllBytesAsync(blob,original); await Tick(c); Check(await c.GetAsync(id) is not null,"repair retries pending receive");
        Check((await c.GetSyncStatusAsync()).Pending == 0 && (await c.GetSyncStatusAsync()).Conflicts.Length == 0
            && (await c.GetAsync(id))!.Name == (await a.GetAsync(id))!.Name, "late join replays all history");
        var reverse=Path.Combine(root,"reverse"); Directory.CreateDirectory(reverse);
        File.Copy(marker,Path.Combine(reverse,"hoverpocket-sync.json"));
        var wire=Directory.GetFiles(Path.Combine(transport,"events"),"*.json",SearchOption.AllDirectories);
        using var d=new AssetStore(Path.Combine(root,"d")); await d.ConfigureSyncAsync(reverse);
        foreach(var file in wire.Reverse())
        {
            var target=Path.Combine(reverse,Path.GetRelativePath(transport,file));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(file,target);
            await d.SyncOnceAsync();
        }
        Check((await d.GetSyncStatusAsync()).Pending > 0, "blob arriving last defers");
        Directory.CreateDirectory(Path.Combine(reverse,"blobs"));
        foreach(var file in Directory.GetFiles(Path.Combine(transport,"blobs")))
            File.Copy(file,Path.Combine(reverse,"blobs",Path.GetFileName(file)));
        await Tick(d);
        var ds=await d.GetSyncStatusAsync();
        Check(ds.Pending==0 && ds.Conflicts.Length==0 && (await d.GetAsync(id))!.Name==(await a.GetAsync(id))!.Name,"reverse delivery and blob last converge");
        var oldEvents=Events();
        await d.SyncOnceAsync(); Check(Events()==oldEvents,"replay does not emit to original transport");

        var duplicateTransport=Path.Combine(root,"duplicates");
        using var e=new AssetStore(Path.Combine(root,"e")); using var f=new AssetStore(Path.Combine(root,"f"));
        var eid=(await e.ImportAsync(source,null,true)).AssetId!; var fid=(await f.ImportAsync(source)).AssetId!;
        await e.ConfigureSyncAsync(duplicateTransport,true); await f.ConfigureSyncAsync(duplicateTransport);
        await Tick(e); await Tick(f); await Tick(e);
        await e.ResolveSyncConflictAsync((await e.GetSyncStatusAsync()).Conflicts.Single().Revision,true); await Tick(f);
        Check((await e.QueryAsync(new())).Total==1 && (await f.QueryAsync(new())).Total==1
            && (await e.GetAsync(eid)) is { InternetOrigin:true } && (await f.GetAsync(fid)) is { InternetOrigin:true } && eid!=fid,"same SHA preserves local IDs and origin protection");

        var originalEvent=Directory.GetFiles(Path.Combine(duplicateTransport,"events"),"*.json",SearchOption.AllDirectories).First();
        var previous=File.ReadAllText(originalEvent);
        var body=AssetSyncFormat.Parse(File.ReadAllBytes(originalEvent));
        await File.WriteAllTextAsync(originalEvent,JsonSerializer.Serialize(body with { Asset=body.Asset! with { Name="改変" } },AssetSyncFormat.Json));
        Check((await e.SyncOnceAsync()).Error is not null,"immutable event tampering rejected");
        await File.WriteAllTextAsync(originalEvent,previous);

        using(var snapshot=new SqliteConnection("Data Source="+Path.Combine(a.Root,"snapshots","sync-before.sqlite")+";Pooling=False"))
        using(var current=new SqliteConnection("Data Source="+Path.Combine(a.Root,"library.sqlite")+";Pooling=False"))
        { snapshot.Open(); current.Open(); current.BackupDatabase(snapshot); }
        await a.UpdateAsync([id],"rename","復元直前"); await Tick(a); await Tick(b);
        var revisionCount=Events(); await a.SetSyncEnabledAsync(false); await a.RestoreDatabaseSnapshotAsync("sync-before.sqlite");
        Check(!(await a.GetSyncStatusAsync()).Enabled && (await a.GetAsync(id))!.Name!="復元直前","paused DB restore retains paused state");
        await a.SetSyncEnabledAsync(true); await Tick(a); await Tick(b);
        Check((await b.GetAsync(id))!.Name==(await a.GetAsync(id))!.Name && (await b.GetSyncStatusAsync()).Conflicts.Length==0 && Events()>revisionCount,"restored metadata makes descendant without head rollback");

        await using(var runner=new AssetSyncRunner(a,TimeSpan.FromMilliseconds(35)))
        {
            await a.UpdateAsync([id],"rename","常駐から同期");
            for(int wait=0; wait<80 && (await b.GetAsync(id))!.Name!="常駐から同期"; wait++) { await Task.Delay(35); await b.SyncOnceAsync(); }
            Check((await b.GetAsync(id))!.Name=="常駐から同期","background loop delivers updates");
        }
        await e.ImportAsync(source, null, true); await Tick(e); await Tick(f);
        Check((await f.GetAsync(fid))!.InternetOrigin && (!OperatingSystem.IsWindows() || File.Exists(f.OriginalPath((await f.GetAsync(fid))!)+":Zone.Identifier")), "internet origin protection never weakens");
        var ef=await e.AddCategoryAsync("folder","同名"); var ff=await f.AddCategoryAsync("folder","同名");
        await Tick(e); await Tick(f); await Tick(e);
        Check((await e.GetSyncStatusAsync()).Conflicts.Length==1 && (await f.GetSyncStatusAsync()).Conflicts.Length==1,"same-name folders preserved as conflicts");
        var blocked=(await e.GetSyncStatusAsync()).Conflicts.Single().Revision;
        await Reject(()=>e.ResolveSyncConflictAsync(blocked,true),"same-name resolution requires repair");
        Check((await e.GetSyncStatusAsync()).Outgoing==0,"failed resolution leaves no exportable event");
        await e.ChangeCategoryAsync(ef,"rename","名前を修正");
        await e.ResolveSyncConflictAsync(blocked,true); await Tick(f);
        Check((await f.GetSyncStatusAsync()).Conflicts.Length==0 && (await f.QueryAsync(new())).Folders.Length==2,"repair then retry preserves both folders");

        var outboxRoot=Path.Combine(root,"outbox-test"); var outboxTransport=Path.Combine(root,"outbox-transport");
        using(var outbox=new AssetStore(outboxRoot))
        {
            await outbox.ConfigureSyncAsync(outboxTransport,true);
            await outbox.ImportAsync(source);
            var blocking=Path.Combine(outboxTransport,"events"); await File.WriteAllTextAsync(blocking,"temporary obstruction");
            Check((await outbox.SyncOnceAsync()).Error is not null && (await outbox.GetSyncStatusAsync()).Outgoing>0,"failed publication retains durable outbox");
            File.Move(blocking,blocking+".preserved");
        }
        using(var reopened=new AssetStore(outboxRoot))
        { await Tick(reopened); Check((await reopened.GetSyncStatusAsync()).Outgoing==0,"restart retries durable outbox"); }

        var syncDbRoot=Path.Combine(root,"damaged-sync");
        using(var damaged=new AssetStore(syncDbRoot))
        {
            await damaged.ConfigureSyncAsync(Path.Combine(root,"damaged-transport"),true);
        }
        await File.WriteAllTextAsync(Path.Combine(syncDbRoot,"library.sqlite"),"broken fixture DB");
        using(var damaged=new AssetStore(syncDbRoot))
        {
            await damaged.Ready;
            await Reject(async ()=>await damaged.RestoreDatabaseSnapshotAsync((await damaged.DatabaseSnapshotsAsync()).First()),"corrupt sync DB refuses unknown history rollback");
        }
        if(OperatingSystem.IsWindows())
        {
            var link=Path.Combine(root,"transport-link");
            var start=new System.Diagnostics.ProcessStartInfo("powershell.exe") { UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true, RedirectStandardError=true };
            foreach(var arg in new[]{"-NoProfile","-Command","New-Item -ItemType Junction -Path '"+link.Replace("'","''")+"' -Target '"+transport.Replace("'","''")+"' | Out-Null"}) start.ArgumentList.Add(arg);
            using var process=System.Diagnostics.Process.Start(start)!; await process.WaitForExitAsync();
            if(process.ExitCode!=0) throw new Exception("junction fixture could not be created");
            using var linked=new AssetStore(Path.Combine(root,"linked"));
            await Reject(()=>linked.ConfigureSyncAsync(link),"junction transport rejected");
        }
        Console.WriteLine(JsonSerializer.Serialize(new{passed=count,root}));
    }
}
