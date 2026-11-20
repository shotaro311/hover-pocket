using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell.Verification;

// Drives "empty trash" and the footer bulk-trash button through the real panel, bridge and store.
internal static class AssetTrashVerifier
{
    private const string Marker = "一括ゴミ箱検査";

    public static async Task RunAsync(HoverShellController controller, List<string> failures)
    {
        var target = controller.ActiveLayoutForVerify!.PanelTarget.PhysicalRect;
        controller.SetPointerSimulationForVerify(target.Left + target.Width / 2, target.Top + 60);
        try
        {
            await VerifyEmptyTrashAsync(controller, failures);
            await VerifyBulkTrashAsync(controller, failures);
        }
        catch (Exception ex) when (ex is TimeoutException or InvalidOperationException) { failures.Add("asset trash: " + ex.Message); }
        finally
        {
            await controller.PanelBridgeController.AssetLibrary.UpdateAsync(
                (await controller.PanelBridgeController.AssetLibrary.QueryAsync(new(Text: Marker, Limit: 200))).Items.Select(item => item.Id).ToArray(), "trash");
            controller.SetPointerSimulationForVerify(target.Left + target.Width / 2, target.Top + 60);
        }
    }

    private static async Task<string[]> ImportAsync(HoverShellController controller, string label, int count)
    {
        var store = controller.PanelBridgeController.AssetLibrary;
        var folder = Path.Combine(store.Root, "fixtures-trash", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(folder);
        var ids = new List<string>();
        for (var i = 0; i < count; i++)
        {
            var path = Path.Combine(folder, $"{Marker} {label} {i}.txt");
            await File.WriteAllTextAsync(path, $"Generated disposable trash fixture {label} {i} {Guid.NewGuid():N}");
            ids.Add((await store.ImportAsync(path)).AssetId!);
        }
        return ids.ToArray();
    }

    private static async Task ShowAssetsAsync(HoverShellController controller, string view)
    {
        await controller.PanelBridgeController.SelectProviderFromShellAsync("assets");
        await controller.ShowPanelForUiVerifyAsync();
        var web = controller.Panel.WebView!;
        await UntilAsync(async () => await web.ExecuteScriptAsync("!!document.querySelector('.assets-root')") == "true");
        // Open the category list the same way a person does in the pocket, then pick the view.
        await web.ExecuteScriptAsync("document.querySelector('.assets-root').classList.add('show-sidebar')");
        await web.ExecuteScriptAsync($$"""
            (()=>{const input=document.querySelector('.assets-search');input.value={{JsonSerializer.Serialize(Marker)}};input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));})()
            """);
        await UntilAsync(async () => await web.ExecuteScriptAsync("document.querySelector('.assets-root').dataset.queryState!=='loading'") == "true");
        var label = view == "trash" ? "ゴミ箱" : "最近の素材";
        await web.ExecuteScriptAsync($$"""[...document.querySelectorAll('.assets-sidebar button')].find(b=>b.textContent==={{JsonSerializer.Serialize(label)}})?.click()""");
        await UntilAsync(async () => await web.ExecuteScriptAsync($$"""(()=>{const b=[...document.querySelectorAll('.assets-sidebar button')].find(b=>b.textContent==={{JsonSerializer.Serialize(label)}});return !!b&&b.classList.contains('is-selected')&&document.querySelector('.assets-root').dataset.queryState!=='loading';})()""") == "true");
    }

    private static async Task VerifyEmptyTrashAsync(HoverShellController controller, List<string> failures)
    {
        var store = controller.PanelBridgeController.AssetLibrary;
        var web = controller.Panel.WebView!;
        var present = await ImportAsync(controller, "空にする", 2);
        var missing = await ImportAsync(controller, "原本なし", 1);
        await store.UpdateAsync([.. present, .. missing], "trash");
        var paths = new List<string>();
        foreach (var id in present) paths.Add(store.OriginalPath((await store.GetAsync(id))!));
        // A trashed row whose original already left the library must not stay in the trash forever.
        var missingPath = store.OriginalPath((await store.GetAsync(missing[0]))!);
        File.SetAttributes(missingPath, FileAttributes.Normal); File.Delete(missingPath);

        await ShowAssetsAsync(controller, "trash");
        await UntilAsync(async () => await web.ExecuteScriptAsync($"document.querySelectorAll('.assets-card').length==={present.Length + missing.Length}") == "true");
        const string emptySelector = ".assets-sidebar .assets-empty-trash";
        var dialogs = new List<string>();
        var watch = WatchForDialogAsync(controller, "ゴミ箱を空にする", dialogs);
        await AssetInteractionVerifier.ClickSurfaceAsync(controller.Panel.WebView!, controller.Panel.WebView!.CoreWebView2, emptySelector);
        var confirmed = await watch;
        VerifyConsole.WriteLine("MEASURE empty trash dialog: " + (dialogs.Count == 0 ? "none" : string.Join(" | ", dialogs)));
        if (!confirmed) { failures.Add("asset trash: empty-trash confirmation did not appear above the panel: " + string.Join(" | ", dialogs)); return; }

        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (DateTime.UtcNow < deadline && (await store.QueryAsync(new(View: "trash", Text: Marker, Limit: 50))).Total > missing.Length) await Task.Delay(50);
        var remaining = (await store.QueryAsync(new(View: "trash", Text: Marker, Limit: 50))).Items;
        await Task.Delay(300);
        var status = JsonSerializer.Deserialize<string>(await web.ExecuteScriptAsync("document.querySelector('.assets-status').textContent")) ?? "";
        var ui = await web.ExecuteScriptAsync("({cards:document.querySelectorAll('.assets-card').length,state:document.querySelector('.assets-root').dataset.queryState})");
        VerifyConsole.WriteLine($"MEASURE empty trash result: remaining={remaining.Length} ({string.Join(",", remaining.Select(a => a.Name))}), status={status}, ui={ui}");
        if (remaining.Any(a => present.Contains(a.Id)) || paths.Any(File.Exists)) failures.Add($"asset trash: empty trash left originals in the library (remaining={remaining.Length}, status={status})");
        else if (!missing.All(id => remaining.Any(a => a.Id == id))) failures.Add($"asset trash: a trashed asset whose original could not be verified was forgotten (status={status})");
        else if (!status.Contains("2件をWindowsのゴミ箱へ移しました") || !status.Contains("1件は原本を確かめられないか使用中のため") || !ui.Contains("\"cards\":1")) failures.Add($"asset trash: empty trash result was not shown (status={status}, ui={ui})");
        else VerifyConsole.WriteLine("PASS empty trash: native click, confirmation above panel, originals sent to the Windows Recycle Bin, a row without its original kept in the trash, list and count updated");
    }

    private static async Task VerifyBulkTrashAsync(HoverShellController controller, List<string> failures)
    {
        var store = controller.PanelBridgeController.AssetLibrary;
        var web = controller.Panel.WebView!;
        var ids = await ImportAsync(controller, "一括", 3);
        await ShowAssetsAsync(controller, "recent");
        await UntilAsync(async () => await web.ExecuteScriptAsync($"document.querySelectorAll('.assets-card').length==={ids.Length}") == "true");
        if (await web.ExecuteScriptAsync("(()=>{const b=document.querySelector('.assets-trash-selection');return !b||b.hidden;})()") != "true")
            failures.Add("asset trash: bulk trash button is shown without a selection");
        await web.ExecuteScriptAsync($$"""
            (()=>{const card=id=>document.querySelector(`[data-asset-id="${id}"]`);
            card({{JsonSerializer.Serialize(ids[0])}}).dispatchEvent(new MouseEvent('click',{bubbles:true}));
            card({{JsonSerializer.Serialize(ids[1])}}).dispatchEvent(new MouseEvent('click',{bubbles:true,ctrlKey:true}));})()
            """);
        await UntilAsync(async () => await web.ExecuteScriptAsync("document.querySelectorAll('[aria-selected=\"true\"]').length===2") == "true");
        if (await web.ExecuteScriptAsync("(()=>{const b=document.querySelector('.assets-trash-selection');return !!b&&!b.hidden&&document.querySelector('.assets-footer').contains(b);})()") != "true")
        { failures.Add("asset trash: footer has no bulk trash button for the selected assets"); return; }
        await AssetInteractionVerifier.ClickSurfaceAsync(web, web.CoreWebView2, ".assets-trash-selection");
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < deadline && !((await store.GetAsync(ids[0]))!.Trashed && (await store.GetAsync(ids[1]))!.Trashed)) await Task.Delay(40);
        await UntilAsync(async () => await web.ExecuteScriptAsync("document.querySelector('.assets-root').dataset.queryState!=='loading'") == "true");
        await Task.Delay(200);
        var status = JsonSerializer.Deserialize<string>(await web.ExecuteScriptAsync("document.querySelector('.assets-status').textContent")) ?? "";
        var trashed = new bool[ids.Length];
        for (var i = 0; i < ids.Length; i++) trashed[i] = (await store.GetAsync(ids[i]))!.Trashed;
        var ui = await web.ExecuteScriptAsync("({cards:document.querySelectorAll('.assets-card').length,hidden:document.querySelector('.assets-trash-selection')?.hidden})");
        VerifyConsole.WriteLine($"MEASURE bulk trash: trashed={string.Join(",", trashed)}, status={status}, ui={ui}");
        if (!trashed[0] || !trashed[1] || trashed[2]) failures.Add("asset trash: bulk trash button did not move exactly the selected assets");
        else if (!status.Contains("2件をゴミ箱へ移しました") || !ui.Contains("\"cards\":1") || !ui.Contains("\"hidden\":true")) failures.Add($"asset trash: bulk trash feedback or list update missing (status={status}, ui={ui})");
        else
        {
            await web.ExecuteScriptAsync("document.querySelector('.assets-scroll').focus();document.querySelector('.assets-scroll').dispatchEvent(new KeyboardEvent('keydown',{key:'z',ctrlKey:true,bubbles:true}))");
            deadline = DateTime.UtcNow.AddSeconds(8);
            while (DateTime.UtcNow < deadline && ((await store.GetAsync(ids[0]))!.Trashed || (await store.GetAsync(ids[1]))!.Trashed)) await Task.Delay(40);
            if ((await store.GetAsync(ids[0]))!.Trashed || (await store.GetAsync(ids[1]))!.Trashed) failures.Add("asset trash: undo did not restore the bulk-trashed assets");
            else VerifyConsole.WriteLine("PASS bulk trash: footer button appears only with a selection, native click trashes exactly the selected assets, feedback shown, undo restores");
        }
    }

    // Confirms the dialog from the dispatcher while MessageBox runs its modal loop.
    private static async Task<bool> WatchForDialogAsync(HoverShellController controller, string title, List<string> trace)
    {
        var panel = controller.Panel.Hwnd;
        var deadline = DateTime.UtcNow.AddSeconds(8);
        while (DateTime.UtcNow < deadline)
        {
            var dialog = FindDialog(title);
            if (dialog != IntPtr.Zero && IsWindowVisible(dialog))
            {
                GetWindowRect(dialog, out var rect);
                var above = false;
                for (var next = GetWindow(dialog, 2); next != IntPtr.Zero; next = GetWindow(next, 2)) if (next == panel) { above = true; break; }
                var owner = GetWindow(dialog, 4);
                trace.Add($"visible owner={(owner == panel ? "panel" : owner.ToString())} abovePanel={above} rect={rect.Left},{rect.Top},{rect.Right},{rect.Bottom} panelVisible={controller.Panel.IsVisible}");
                await Task.Delay(150);
                PostMessage(dialog, 0x0111, (IntPtr)1, GetDlgItem(dialog, 1));
                return above && controller.Panel.IsVisible;
            }
            await Task.Delay(40);
        }
        return false;
    }

    private static IntPtr FindDialog(string title)
    {
        var pid = (uint)Environment.ProcessId; var found = IntPtr.Zero;
        EnumWindows((hwnd, _) =>
        {
            GetWindowThreadProcessId(hwnd, out var owner); if (owner != pid) return true;
            var name = new StringBuilder(256); GetClassName(hwnd, name, name.Capacity); if (name.ToString() != "#32770") return true;
            var text = new StringBuilder(256); GetWindowText(hwnd, text, text.Capacity);
            if (text.ToString() == title) { found = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    private static async Task UntilAsync(Func<Task<bool>> ready, [System.Runtime.CompilerServices.CallerLineNumber] int line = 0)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!await ready()) { if (DateTime.UtcNow > deadline) throw new TimeoutException($"Asset trash verification timed out at line {line}."); await Task.Delay(30); }
    }

    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    private delegate bool EnumProc(IntPtr hwnd, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int capacity);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out NativeRect rect);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("user32.dll")] private static extern IntPtr GetDlgItem(IntPtr dialog, int id);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
}
