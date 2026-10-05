using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HoverPocket.Assets;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Capture;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.Voice;
using HoverPocket.Shell.Windows;
using Brushes = System.Windows.Media.Brushes;

namespace HoverPocket.Shell.Verification;

internal static class VoiceLibraryVerifier
{
    public static async Task<int> RunAsync(HoverShellController controller)
    {
        var store = controller.PanelBridgeController.AssetLibrary;
        var root = Path.Combine(Path.GetDirectoryName(store.Root)!, "VoiceLibraryVerify");
        Directory.CreateDirectory(root);
        File.WriteAllText(Path.Combine(root, "capture-settings.json"), JsonSerializer.Serialize(new CapturePreferences("Ctrl+Alt+F23", "Ctrl+Alt+F24", false, false, ScreenshotToastSeconds: 0)));
        var fixture = new Window { Title = "HoverPocket voice capture fixture " + Guid.NewGuid().ToString("N"), Width = 460, Height = 300,
            Left = 200, Top = 200, Topmost = true, Content = new Border { Background = Brushes.MediumPurple, Child = new TextBlock {
                Text = "音声から撮影・保存\n検証専用ウィンドウ", FontSize = 28, Foreground = Brushes.White, Margin = new Thickness(24) } } };
        Window? duplicate = null;
        using var capture = new CaptureController(store, root, () => Task.CompletedTask, () => { }, () => { }, allowOwnWindowsForVerify: true);
        using var timers = new TimerStore(Path.Combine(root, "timer"), new ManualTimerClock(DateTimeOffset.UtcNow), new NullTimerAlertSound(), enableScheduler: false);
        try
        {
            await controller.HideForCaptureAsync();
            await store.Ready;
            fixture.Show();
            for (var attempt = 0; attempt < 20 && !fixture.IsActive; attempt++)
            {
                Interop.NativeMethods.ActivateWindowForTextInput(new System.Windows.Interop.WindowInteropHelper(fixture).Handle);
                fixture.Activate();
                await Task.Delay(100);
            }
            Require(fixture.IsActive, "fixture foreground activation");
            await Task.Delay(100);
            Require(capture.VoiceTargets.Resolve("current_window", null, null).Title == fixture.Title, "last active window");
            var monitorTarget = capture.VoiceTargets.Resolve("screen", null, null);
            Require(monitorTarget.Monitor, "screen target resolution without capturing display");
            try { capture.VoiceTargets.Resolve("window", monitorTarget.Id, null); throw new InvalidOperationException("screen ID accepted as window"); } catch (ArgumentException) { }
            var handlers = ProviderCapabilityCompositionRoot.Create(new FakeCalendarCapabilityDataSource(), timers, new StickyNotesStore(Path.Combine(root, "sticky")), new FakeControlsCapabilityDataSource());
            var library = new VoiceLibraryCapabilities(store, () => capture, fixture.Dispatcher, controller.OpenAssetLibraryForVoiceAsync);
            library.Register(handlers);
            var registry = new CapabilityRegistry(handlers, PocketCapabilityDescriptors.BuiltIn.Concat(VoiceLibraryCapabilities.Descriptors));
            var broker = new CapabilityBroker(registry, new CapabilityBrokerLedger(Path.Combine(root, "broker")), new CapabilityBrokerAuditLog(Path.Combine(root, "broker")));
            var approved = false; var approvals = 0; VoiceNativeApproval? approval = null;
            var runtime = new CodexNativeCapabilityRuntime(new CodexRealtimeCapabilityAdapter(new OpenAIRealtimeCapabilityRuntime(
                new BrokerOpenAIRealtimeCapabilityAuthority(registry, broker), (_, _) => Task.FromResult(false), (_, _) => Task.FromResult(false), () => true, () => "Asia/Tokyo")),
                registry, broker, (request, _) => { approvals++; approval = request; return Task.FromResult(approved); }, library);
            Require(runtime.Definitions.GetArrayLength() == 19, "full tool catalog");
            Task<CodexVoiceDynamicToolResponse> Call(string id, string name, object args, string thread = "voice-library", CancellationToken token = default) =>
                Task.Run(() => runtime.ExecuteAsync(JsonSerializer.SerializeToElement(new { threadId = thread, callId = id, tool = name, arguments = args }), "voice-library", token));
            var query = await Call("windows", "capture_windows_list", new { query = fixture.Title });
            Require(query.Success && query.Text.Contains(fixture.Title), "native window query");
            var windowId = Output(query).GetProperty("windows")[0].GetProperty("windowId").GetString()!;
            var before = (await store.QueryAsync(new())).Total;
            var denied = await Call("denied", "capture_screenshot_save", new { target = "window", windowId });
            Require(!denied.Success && (await store.QueryAsync(new())).Total == before && approval!.Details.Contains(fixture.Title), "capture denial and exact target approval");
            Require(!(await Call("foreign", "capture_screenshot_save", new { target = "window", windowId }, "wrong-root")).Success, "foreign root");
            Require(!(await Call("path", "capture_screenshot_save", new { path = "C:\\private.png" })).Success, "arbitrary path");
            Require(!(await Call("token", "capture_screenshot_save", new { targetToken = windowId })).Success, "host target token injection");
            Require(!(await Call("limit", "library_search", new { limit = 100 })).Success, "bounded search");
            Require(!(await Call("type", "library_search", new { limit = "ten" })).Success, "invalid search type");
            duplicate = new Window { Title = fixture.Title, Width = 120, Height = 100, Left = 700, Top = 200 };
            duplicate.Show();
            Require(!(await Call("ambiguous", "capture_screenshot_save", new { target = "window", windowTitle = fixture.Title })).Success, "ambiguous title");
            duplicate.Close(); duplicate = null;
            approved = true;
            var folderResult = await Call("folder", "library_folder_create", new { name = "音声テスト" });
            Require(folderResult.Success, "create folder: " + folderResult.Text);
            var folderId = Output(folderResult).GetProperty("folder").GetProperty("id").GetString()!;
            var shot = await Call("shot", "capture_screenshot_save", new { target = "window", windowId, name = "音声スクショ", folderId });
            Require(shot.Success, "screenshot: " + shot.Text);
            var assetId = Output(shot).GetProperty("asset").GetProperty("id").GetString()!;
            Require((await Call("shot", "capture_screenshot_save", new { target = "window", windowId, name = "音声スクショ", folderId })) == shot, "duplicate screenshot");
            Require((await store.QueryAsync(new())).Total == before + 1, "exactly one screenshot");
            var asset = (await store.GetAsync(assetId))!;
            Require(asset.FolderIds.Contains(folderId) && asset.Name == "音声スクショ", "screenshot classification");
            using (var imageStream = File.OpenRead(store.ReadOriginalPath(asset)))
            {
                var decoder = new PngBitmapDecoder(imageStream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                Require(decoder.Frames[0].PixelWidth >= 400 && decoder.Frames[0].PixelHeight >= 230, "native PNG dimensions");
            }
            var evidence = Environment.GetEnvironmentVariable("HOVERPOCKET_VOICE_LIBRARY_EVIDENCE");
            if (!string.IsNullOrEmpty(evidence)) evidence = Path.Combine(evidence, Guid.NewGuid().ToString("N"));
            if (!string.IsNullOrEmpty(evidence)) { Directory.CreateDirectory(evidence); File.Copy(store.ReadOriginalPath(asset), Path.Combine(evidence, "voice-window-screenshot.png"), true); }
            Require((await Call("rename", "library_asset_rename", new { assetId, name = "名前変更の確認" })).Success, "rename");
            Require((await Call("favorite", "library_asset_favorite", new { assetId, favorite = true })).Success, "favorite");
            Require((await Call("favorite2", "library_asset_favorite", new { assetId, favorite = true })).Success && (await store.GetAsync(assetId))!.Favorite, "set favorite does not toggle");
            var folder2 = await store.AddCategoryAsync("folder", "分類の確認");
            Require((await Call("classify", "library_asset_classify", new { assetId, folderId = folder2 })).Success && (await store.GetAsync(assetId))!.FolderIds.Length == 2, "add folder preserves membership");
            var found = await Call("search", "library_search", new { text = "名前変更", favorites = true, folderId = folder2 });
            Require(found.Success && Output(found).GetProperty("total").GetInt32() == 1, "metadata search: " + found.Text);
            var opened = await Call("open", "library_open", new { assetId });
            Require(opened.Success, "native library preview: " + opened.Text);
            fixture.Title += " changed";
            Require(!(await Call("stale", "capture_screenshot_save", new { target = "window", windowId })).Success, "stale target");
            using (var cancelled = new CancellationTokenSource())
            {
                cancelled.Cancel();
                Require(!(await Call("cancelled", "capture_recording_start", new { target = "window", windowTitle = fixture.Title }, token: cancelled.Token)).Success && !capture.Recording && !capture.Busy, "cancelled capture");
            }
            var rec = await Call("record", "capture_recording_start", new { target = "window", windowTitle = fixture.Title, systemAudio = false, microphone = false, name = "音声収録", folderId });
            Require(rec.Success && capture.Recording && approval!.Details.Contains("マイク: 含めない"), "recording start: " + rec.Text);
            Require((await Call("record", "capture_recording_start", new { target = "window", windowTitle = fixture.Title, systemAudio = false, microphone = false, name = "音声収録", folderId })) == rec && capture.Recording, "duplicate recording must not toggle stop");
            Require(!(await Call("busy", "capture_screenshot_save", new { target = "window", windowTitle = fixture.Title })).Success, "busy capture");
            await Task.Delay(1200);
            var approvalCount = approvals;
            var stop = await Call("stop", "capture_recording_stop", new { });
            Require(stop.Success && !capture.Recording && approvals == approvalCount, "stop saves without extra confirmation: " + stop.Text);
            var videoId = Output(stop).GetProperty("assets")[0].GetProperty("id").GetString()!;
            var video = (await store.GetAsync(videoId))!;
            var properties = await (await global::Windows.Storage.StorageFile.GetFileFromPathAsync(store.ReadOriginalPath(video))).Properties.GetVideoPropertiesAsync();
            Require(video.Kind == "video" && video.Name == "音声収録" && video.FolderIds.Contains(folderId) && properties.Duration.TotalMilliseconds > 300 && properties.Width > 0, "valid MP4 readback");
            Require((await Call("video-preview", "library_open", new { assetId = videoId })).Success, "recording library preview");
            var web = controller.AssetOrganizerForVerify!.WebViewForVerify!;
            for (var attempt = 0; attempt < 50 && await web.ExecuteScriptAsync("!!document.querySelector('video')?.videoWidth") != "true"; attempt++) await Task.Delay(100);
            Require(await web.ExecuteScriptAsync("!!document.querySelector('video')?.videoWidth && document.querySelector('video').paused") == "true", "recording decoded without autoplay");
            if (!string.IsNullOrEmpty(evidence)) File.Copy(store.ReadOriginalPath(video), Path.Combine(evidence, "voice-window-recording.mp4"), true);
            Require((await Call("stop", "capture_recording_stop", new { })) == stop, "duplicate stop");
            var next = await Call("next", "capture_recording_start", new { target = "window", windowTitle = fixture.Title, systemAudio = false, microphone = false });
            Require(next.Success, "next recording");
            Require((await Call("stop", "capture_recording_stop", new { })) == stop && capture.Recording, "old duplicate stop cannot stop next recording");
            await Task.Delay(700);
            fixture.Close();
            for (var i = 0; capture.Recording && i < 100; i++) await Task.Delay(100);
            Require(!capture.Recording && capture.VoiceState.SavedAssetIds.Length == 1 && capture.VoiceState.Error is null, "closed target saves recording");
            var state = await Call("status", "capture_recording_status", new { });
            Require(state.Success && Output(state).GetProperty("state").GetProperty("savedAssetIds").GetArrayLength() == 1, "recording status saved readback");
            using var routeTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(65));
            var installed = new InstalledCodexVoiceRuntime(Path.Combine(root, "CodexHome"), () => runtime.Definitions, false);
            var gate = await installed.ProbeAsync(routeTimeout.Token);
            Require(gate.IsReady, "all 19 tools installed route: " + gate.SafeErrorCode);
            VerifyConsole.WriteLine("PASS voice-library: 19-tool exact Codex route; real fixture PNG/MP4; target/denial/root/bounds/stale/busy/cancel guards; metadata readback; native preview; duplicate start/stop; automatic save on target close; no microphone/system audio or production-data writes");
            VerifyConsole.WriteLine("VOICE_LIBRARY_EVIDENCE " + root);
            return 0;
        }
        catch (Exception exception) { VerifyConsole.WriteLine("FAIL voice-library: " + exception); return 1; }
        finally { await capture.StopRecordingAsync(); duplicate?.Close(); fixture.Close(); controller.RestoreAfterCapture(); }
    }
    private static JsonElement Output(CodexVoiceDynamicToolResponse response) => JsonDocument.Parse(response.Text).RootElement.GetProperty("output").Clone();
    private static void Require(bool value, string reason) { if (!value) throw new InvalidOperationException(reason); }
}
