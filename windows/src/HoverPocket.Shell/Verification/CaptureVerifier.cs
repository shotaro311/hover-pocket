using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HoverPocket.Assets;
using HoverPocket.Shell.Capture;
using HoverPocket.Shell.Providers.Assets;
using HoverPocket.Shell.Providers.Controls;
using HoverPocket.Shell.Windows;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using Windows.Storage;
using Brushes = System.Windows.Media.Brushes;

namespace HoverPocket.Shell.Verification;

internal static class CaptureVerifier
{
    public static async Task<int> RunAsync(HoverShellController controller)
    {
        var root = Path.Combine(Path.GetTempPath(), "HoverPocket", "CaptureVerify", Guid.NewGuid().ToString("N"));
        var failures = new List<string>(); Window? fixture = null; ScreenshotEditorWindow? editor = null;
        try
        {
            await controller.HideForCaptureAsync();
            try
            {
                var entry = controller.Layouts[0].AccessSurface.PhysicalRect;
                controller.SimulatePointerMoveForVerify(entry.Left + entry.Width / 2, entry.Top);
                controller.ShowPanelFromUser();
                controller.ScheduleStagedRecoveryForVerify();
                await controller.RunHealthCheckForVerifyAsync();
                if (controller.Panel.IsVisible || controller.PollingEnabledForVerify || controller.HealthTimerEnabledForVerify)
                    failures.Add("panel reappeared while capturing");
            }
            finally { controller.ClearPointerSimulationForVerify(); controller.RestoreAfterCapture(); }
            if (!controller.PollingEnabledForVerify || !controller.HealthTimerEnabledForVerify) failures.Add("capture shell restoration");
            VerifyConsole.WriteLine("PASS capture: shell stays hidden during pointer/recovery notifications and resumes after selection");
            using var store = new AssetStore(root, AssetRecycle.MoveAsync); await store.Ready;
            var folder = await store.AddCategoryAsync("folder", "撮影した素材");
            var captureFiles = new CaptureFiles(store);
            var pixels = Enumerable.Repeat((byte)235, 160 * 100 * 4).ToArray(); for (var i = 3; i < pixels.Length; i += 4) pixels[i] = 255;
            var source = BitmapSource.Create(160, 100, 96, 96, PixelFormats.Bgra32, null, pixels, 160 * 4); source.Freeze();
            var legacyPreferences = System.Text.Json.JsonSerializer.Deserialize<CapturePreferences>("{\"SystemAudio\":false}");
            if (legacyPreferences?.OpenEditorAfterScreenshot != true) failures.Add("legacy editor default changed");
            var editorOpened = false;
            var direct = CaptureController.EditScreenshot(source, false, _ => { editorOpened = true; return null; });
            if (editorOpened || direct?.Image != source || direct.KeepOriginal) failures.Add("editor disabled did not use direct capture");
            var cancelledEdit = CaptureController.EditScreenshot(source, true, window => { editorOpened = true; window.Close(); return null; });
            if (!editorOpened || cancelledEdit is not null) failures.Add("editor enabled/cancelled result");
            VerifyConsole.WriteLine("PASS capture editor preference: legacy default on, bypass keeps original pixels, enabled/cancel routes correctly");
            var crop = ScreenshotSelectionWindow.Crop(source, new(10, 10, 130, 80));
            if (crop.PixelWidth != 130 || crop.PixelHeight != 80) failures.Add("crop dimensions");
            editor = new ScreenshotEditorWindow(source); editor.Show(); await Task.Delay(120);
            var original = ReadPixels(editor.RenderImage()); editor.AddAnnotationsForVerify(); var annotated = editor.RenderImage(); var annotatedPixels = ReadPixels(annotated);
            if (original.SequenceEqual(annotatedPixels)) failures.Add("annotations absent from render");
            editor.Undo(); if (!ReadPixels(editor.RenderImage()).SequenceEqual(original)) failures.Add("annotation undo");
            editor.Redo(); if (!ReadPixels(editor.RenderImage()).SequenceEqual(annotatedPixels)) failures.Add("annotation redo");
            if (Environment.GetEnvironmentVariable("HOVERPOCKET_CAPTURE_EVIDENCE") is { Length: > 0 } evidence)
            {
                var windowImage = new RenderTargetBitmap((int)editor.ActualWidth, (int)editor.ActualHeight, 96, 96, PixelFormats.Pbgra32); windowImage.Render(editor); windowImage.Freeze(); await CaptureFiles.WritePngAsync(evidence, windowImage);
            }
            var imageStage = captureFiles.CreateStage(); var imagePath = Path.Combine(imageStage, "edited.png"); await CaptureFiles.WritePngAsync(imagePath, annotated);
            CaptureFiles.MarkComplete(imageStage, [imagePath], folder); await captureFiles.ImportCompletedAsync(imageStage);
            var page = await store.QueryAsync(new(FolderId: folder)); if (page.Items.Length != 1 || page.Items[0].Kind != "image") failures.Add("edited image library classification");
            await VerifyImageEditingAsync(root, source, annotated, failures);
            editor.Close(); editor = null;
            var callbacks = new List<bool>(); using (var keys = new CaptureHotkeys(callbacks.Add))
            {
                var result = keys.Apply("Ctrl+Alt+F21", "Ctrl+Alt+F22"); if (result.Contains("使用中")) failures.Add("isolated hotkey registration conflict");
                SendMessage(keys.HandleForVerify, 0x0312, 1, 0); SendMessage(keys.HandleForVerify, 0x0312, 2, 0);
                if (!callbacks.SequenceEqual(new[] { false, true })) failures.Add("hotkey native dispatch");
                using (var conflict = new CaptureHotkeys(_ => { })) if (!conflict.Apply("Ctrl+Alt+F21", "Ctrl+Alt+F22").Contains("使用中")) failures.Add("hotkey conflict not reported");
                try { keys.Apply("Ctrl+Alt+S", "Ctrl+Alt+S"); failures.Add("duplicate shortcut accepted"); } catch (ArgumentException) { }
            }
            using (var secondKeys = new CaptureHotkeys(_ => { })) if (secondKeys.Apply("Ctrl+Alt+F21", "Ctrl+Alt+F22").Contains("使用中")) failures.Add("hotkeys not unregistered");
            using (var configuration = new CaptureController(store, root, () => Task.CompletedTask, () => { }, () => { }))
            {
                configuration.SavePreferences(new("Ctrl+Alt+F23", "Ctrl+Alt+F24", false, true, folder, false));
                var savedPreferences = System.Text.Json.JsonSerializer.Deserialize<CapturePreferences>(File.ReadAllText(Path.Combine(root, "capture-settings.json")))!;
                if (savedPreferences.FolderId != folder || savedPreferences.SystemAudio || !savedPreferences.Microphone || savedPreferences.OpenEditorAfterScreenshot) failures.Add("capture settings persistence");
                var ownerHandle = nint.Zero;
                await configuration.ToggleRecordingAsync(handle =>
                {
                    ownerHandle = handle;
                    var pickerOwner = HwndSource.FromHwnd(handle)?.RootVisual is Window { Content: null, ShowInTaskbar: false } and not CaptureWindow;
                    if (!IsWindow(handle) || !pickerOwner || configuration.WindowPreferencesForVerify is not null) failures.Add("recording opened settings or invalid picker owner");
                    return Task.FromResult<global::Windows.Graphics.Capture.GraphicsCaptureItem?>(null);
                });
                if (configuration.Busy || configuration.Recording || configuration.WindowPreferencesForVerify is not null || IsWindow(ownerHandle)) failures.Add("recording cancellation did not clean hidden owner");
                var errors = 0; configuration.RecordingError += _ => errors++;
                await configuration.ToggleRecordingAsync(_ => throw new IOException("verification picker failure"));
                if (errors != 1 || configuration.Busy || configuration.WindowPreferencesForVerify is not null) failures.Add("recording picker error reporting/cleanup");
                var nativePicker = configuration.ToggleRecordingAsync();
                VerifyConsole.WriteLine($"PICKER native: foreground_owned={Interop.NativeMethods.ForegroundBelongsToCurrentProcess()}, owner_visible={IsWindowVisible(configuration.RecordingOwnerForVerify)}");
                var pickerClosed = false;
                var pickerDeadline = DateTime.UtcNow.AddSeconds(20);
                var pickerSnapshotTaken = false;
                while (!nativePicker.IsCompleted && DateTime.UtcNow < pickerDeadline)
                {
                    await Task.Delay(50);
                    var owner = configuration.RecordingOwnerForVerify;
                    if (!pickerSnapshotTaken && DateTime.UtcNow > pickerDeadline.AddSeconds(-18))
                    {
                        pickerSnapshotTaken = true;
                        var snapshot = await Task.Run(() => ScreenshotSelectionWindow.CaptureDesktop(System.Windows.Forms.SystemInformation.VirtualScreen));
                        if (Environment.GetEnvironmentVariable("HOVERPOCKET_CAPTURE_EVIDENCE") is { Length: > 0 } evidencePath)
                            await CaptureFiles.WritePngAsync(Path.Combine(Path.GetDirectoryName(evidencePath)!, "picker-native.png"), snapshot);
                    }
                    EnumWindows((handle, _) =>
                    {
                        var title = new System.Text.StringBuilder(200); GetWindowText(handle, title, title.Capacity);
                        var pickerTitle = title.ToString();
                        var systemPicker = pickerTitle.Contains("HoverPocket — 画面収録") && (pickerTitle.Contains("キャプチャ") || pickerTitle.Contains("capture", StringComparison.OrdinalIgnoreCase));
                        if (handle != owner && owner != 0 && IsWindowVisible(handle) && (GetAncestor(handle, 3) == owner || systemPicker))
                        { PostMessage(handle, 0x0010, 0, 0); pickerClosed = true; }
                        return true;
                    }, 0);
                }
                await nativePicker.WaitAsync(TimeSpan.FromSeconds(3));
                if (!pickerClosed || errors != 1 || configuration.WindowPreferencesForVerify is not null || configuration.Busy) failures.Add($"native recording picker without settings/cancel: owned_picker={pickerClosed}, errors={errors}, busy={configuration.Busy}, status={configuration.Status}");
                else VerifyConsole.WriteLine("PASS recording native picker: system picker shown without settings, native cancel returns cleanly");
                configuration.Open(); configuration.Open(null, useCurrentFolder: true);
                if (configuration.WindowPreferencesForVerify?.FolderId is not null) failures.Add("root capture folder before load");
                await Task.Delay(100);
                if (configuration.WindowPreferencesForVerify?.FolderId is not null) failures.Add("root capture folder after load");
                configuration.Open(folder, useCurrentFolder: true);
                if (configuration.WindowPreferencesForVerify?.FolderId != folder) failures.Add("current named capture folder");
                using var selection = new DisposableWindow(new ScreenshotSelectionWindow(source, new System.Drawing.Rectangle(100, 100, 480, 300)));
                selection.Window.Show(); await Task.Delay(100); GetWindowRect(new WindowInteropHelper(selection.Window).Handle, out var rect);
                if (rect.Left != 100 || rect.Top != 100 || rect.Right - rect.Left != 480 || rect.Bottom - rect.Top != 300) failures.Add("native screenshot selection bounds");
            }
            var pcm = CaptureAudio.ToPcm16(new float[] { -2, -.5f, 0, .5f, 2 });
            if (System.Buffers.Binary.BinaryPrimitives.ReadInt16LittleEndian(pcm) != -32767 || System.Buffers.Binary.BinaryPrimitives.ReadInt16LittleEndian(pcm.AsSpan(8)) != 32767) failures.Add("audio clipping");
            VerifyConsole.WriteLine("PASS capture: crop, pen/text/rectangle/ellipse/arrow rendering, undo/redo, classified PNG, native region overlay, hotkey conflict/dispatch/unregister, settings persistence, root/named folder handoff before/after load, PCM clipping");
            var quadrants = new Grid();
            quadrants.RowDefinitions.Add(new()); quadrants.RowDefinitions.Add(new());
            quadrants.ColumnDefinitions.Add(new()); quadrants.ColumnDefinitions.Add(new());
            var colors = new[] { Brushes.Red, Brushes.Lime, Brushes.Blue, Brushes.Yellow };
            for (var quadrant = 0; quadrant < 4; quadrant++)
            {
                var block = new Border { Background = colors[quadrant], Child = new TextBlock { Text = new[] { "TOP LEFT", "TOP RIGHT", "BOTTOM LEFT", "BOTTOM RIGHT" }[quadrant], FontSize = 24, Margin = new(25) } };
                Grid.SetRow(block, quadrant / 2); Grid.SetColumn(block, quadrant % 2); quadrants.Children.Add(block);
            }
            fixture = new Window { Title = "HoverPocket recording verification (generated content)", Width = 640, Height = 400, WindowStartupLocation = WindowStartupLocation.CenterScreen, Content = quadrants };
            fixture.Topmost = true; fixture.Show(); await Task.Delay(250);
            GetWindowRect(new WindowInteropHelper(fixture).Handle, out var fixtureBounds);
            var desktopSnapshot = await Task.Run(() => ScreenshotSelectionWindow.CaptureDesktop(new System.Drawing.Rectangle(fixtureBounds.Left, fixtureBounds.Top, fixtureBounds.Right - fixtureBounds.Left, fixtureBounds.Bottom - fixtureBounds.Top)));
            if (desktopSnapshot.PixelWidth != fixtureBounds.Right - fixtureBounds.Left) failures.Add("native screen snapshot");
            // Exercise the production worker -> UI crop -> worker PNG path, not only generated UI-thread images.
            var desktopCrop = ScreenshotSelectionWindow.Crop(desktopSnapshot, new(10, 10, 130, 80));
            var screenshotStage = captureFiles.CreateStage();
            await CaptureFiles.WritePngAsync(Path.Combine(screenshotStage, "cropped.png"), desktopCrop);
            await CaptureFiles.WritePngAsync(Path.Combine(screenshotStage, "original.png"), desktopSnapshot);
            var nativeBounds = new System.Drawing.Rectangle(fixtureBounds.Left, fixtureBounds.Top, fixtureBounds.Right - fixtureBounds.Left, fixtureBounds.Bottom - fixtureBounds.Top);
            for (var attempt = 0; attempt < 3; attempt++)
            {
                var snapshot = await Task.Run(() => ScreenshotSelectionWindow.CaptureDesktop(nativeBounds));
                var selected = SelectSnapshot(snapshot, nativeBounds, window => window.CompleteSelection(new(10, 10, 130, 80)));
                if (selected.Error is not null || selected.Result is not { PixelWidth: 130, PixelHeight: 80 }) failures.Add("modal worker screenshot crop");
                using var selectedEditor = new DisposableWindow(new ScreenshotEditorWindow(selected.Result!));
                selectedEditor.Window.Show(); await Task.Delay(50);
                var screenshotEditor = (ScreenshotEditorWindow)selectedEditor.Window;
                screenshotEditor.AddAnnotationsForVerify();
                var rendered = screenshotEditor.RenderImage();
                await CaptureFiles.WritePngAsync(Path.Combine(screenshotStage, $"edited-{attempt}.png"), rendered);
                var decoded = new BitmapImage(); decoded.BeginInit(); decoded.CacheOption = BitmapCacheOption.OnLoad; decoded.UriSource = new Uri(Path.Combine(screenshotStage, $"edited-{attempt}.png")); decoded.EndInit();
                if (!ReadPixels(decoded).SequenceEqual(ReadPixels(rendered))) failures.Add("screenshot PNG pixels changed");
            }
            var whole = SelectSnapshot(desktopSnapshot, nativeBounds, window => SelectionKey(window, System.Windows.Input.Key.Enter));
            if (whole.Error is not null || !ReferenceEquals(whole.Result, desktopSnapshot)) failures.Add("screenshot Enter full screen");
            var cancelled = SelectSnapshot(desktopSnapshot, nativeBounds, window => SelectionKey(window, System.Windows.Input.Key.Escape));
            if (cancelled.Error is not null || cancelled.Result is not null) failures.Add("screenshot Escape cancel");
            var invalid = SelectSnapshot(desktopSnapshot, nativeBounds, window => window.CompleteSelection(new(-1, 0, 10, 10)));
            if (invalid.Error is null || invalid.Result is not null) failures.Add("screenshot crop error boundary");
            var selectedByMouse = SelectSnapshot(desktopSnapshot, nativeBounds, window =>
            {
                var handle = new WindowInteropHelper(window).Handle;
                GetCursorPos(out var cursor);
                try
                {
                    SetCursorPos(nativeBounds.Left + 60, nativeBounds.Top + 90);
                    SendMessage(handle, 0x0201, 1, new nint((90 << 16) | 60));
                    SetCursorPos(nativeBounds.Left + 255, nativeBounds.Top + 210);
                    SendMessage(handle, 0x0200, 1, new nint((210 << 16) | 255));
                    SendMessage(handle, 0x0202, 0, new nint((210 << 16) | 255));
                }
                finally { SetCursorPos(cursor.X, cursor.Y); }
                if (window.IsVisible) { failures.Add("native screenshot drag did not close selection"); window.Close(); }
            });
            if (selectedByMouse.Error is not null || selectedByMouse.Result is not { PixelWidth: >= 194 and <= 196, PixelHeight: >= 119 and <= 121 }) failures.Add("native screenshot drag crop");
            await AssetRecycle.MoveAsync(screenshotStage);
            VerifyConsole.WriteLine("PASS capture: repeated worker desktop capture -> modal selection -> annotated PNG pixel readback, original PNG, native mouse drag, Enter, Escape, crop error boundary");
            var item = WindowsGraphicsCapturePreviewService.CreateCaptureItemForWindow(new WindowInteropHelper(fixture).Handle);
            using (var shortcut = new CaptureController(store, Path.Combine(root, "shortcut"), () => Task.CompletedTask, () => { }, () => { }))
            {
                shortcut.SavePreferences(new("Ctrl+Alt+F23", "Ctrl+Alt+F24", false, false, folder, false));
                await shortcut.ToggleRecordingAsync(_ => Task.FromResult<global::Windows.Graphics.Capture.GraphicsCaptureItem?>(item));
                await Task.Delay(500);
                if (!shortcut.Recording || shortcut.WindowPreferencesForVerify is not null) failures.Add("recording shortcut opened settings");
                shortcut.Open();
                System.Windows.Application.Current.Windows.OfType<CaptureWindow>().Single().Close();
                if (!shortcut.Recording) failures.Add("closing recording settings stopped recording");
                await shortcut.ToggleRecordingAsync();
                var shortcuts = await store.QueryAsync(new(FolderId: folder));
                var recorded = shortcuts.Items.SingleOrDefault(asset => asset.Kind == "video");
                if (shortcut.Recording || shortcut.Busy || recorded is null) failures.Add("recording shortcut stop/save");
                if (recorded is not null) await store.UpdateAsync([recorded.Id], "trash", null);
                VerifyConsole.WriteLine("PASS recording shortcut: hidden valid picker owner, cancel/error cleanup, saved options, no settings on start/stop, settings close keeps recording, classified save");
            }
            var videoStage = captureFiles.CreateStage(); var videoPath = Path.Combine(videoStage, "recorded.mp4"); using (File.Create(videoPath)) { }
            using var tone = new WasapiPlayerBuilder().Build(); tone.Init(new SignalGenerator(48000, 2) { Gain = .03, Frequency = 660, Type = SignalGeneratorType.Sin }.ToWaveProvider());
            using var recorder = await ScreenRecorder.StartAsync(item, videoPath, true, true);
            tone.Play(); await Task.Delay(2200); recorder.Stop(); await recorder.Completion.WaitAsync(TimeSpan.FromSeconds(20)); tone.Stop();
            var file = await StorageFile.GetFileFromPathAsync(videoPath); var properties = await file.Properties.GetVideoPropertiesAsync();
            if (recorder.VideoFrames < 2 || properties.Duration.TotalSeconds < .5 || properties.Width == 0) failures.Add("recorded video empty");
            if (recorder.MicrophonePackets == 0) failures.Add("microphone packets missing");
            await VerifyVideoOrientationAsync(videoPath, "audio", failures);
            var soundEnergy = 0d;
            using (var audio = new NAudio.Wave.MediaFoundationReader(videoPath))
            { var samples = audio.ToSampleProvider(); var data = new float[48000 * 2]; var count = samples.Read(data.AsSpan()); soundEnergy = data.Take(count).Select(value => (double)value * value).Sum(); if (count == 0 || soundEnergy < .00001) failures.Add("loopback AAC audio missing"); }
            CaptureFiles.MarkComplete(videoStage, [videoPath], folder); await captureFiles.ImportCompletedAsync(videoStage);
            page = await store.QueryAsync(new(FolderId: folder)); if (page.Total != 2 || page.Items.All(asset => asset.Kind != "video")) failures.Add("recording library classification");
            VerifyConsole.WriteLine($"PASS recording: frames={recorder.VideoFrames}, duration_ms={properties.Duration.TotalMilliseconds:0}, dimensions={properties.Width}x{properties.Height}, audio_track_nonzero={soundEnergy > .00001}, microphone_packets={recorder.MicrophonePackets}, automatic_import=true");
            var silentStage = captureFiles.CreateStage(); var silentPath = Path.Combine(silentStage, "silent.mp4"); using (File.Create(silentPath)) { }
            using (var silent = await ScreenRecorder.StartAsync(item, silentPath, false, false))
            {
                await Task.Delay(600); fixture.Width += 80; await silent.Completion.WaitAsync(TimeSpan.FromSeconds(12));
                if (silent.HasAudio || silent.VideoFrames == 0 || silent.StopReason is null) failures.Add("silent recording resize stop");
                await VerifyVideoOrientationAsync(silentPath, "silent", failures);
                CaptureFiles.MarkComplete(silentStage, [silentPath], folder); await captureFiles.ImportCompletedAsync(silentStage);
            }
            fixture.Width = 1800; fixture.Height = 1000; await Task.Delay(200);
            var largeItem = WindowsGraphicsCapturePreviewService.CreateCaptureItemForWindow(new WindowInteropHelper(fixture).Handle);
            var scaledPath = Path.Combine(root, "scaled.mp4"); using (File.Create(scaledPath)) { }
            using (var scaled = await ScreenRecorder.StartAsync(largeItem, scaledPath, false, false))
            {
                await Task.Delay(700); scaled.Stop(); await scaled.Completion.WaitAsync(TimeSpan.FromSeconds(20));
                await VerifyVideoOrientationAsync(scaledPath, "scaled", failures);
                var scaledProperties = await (await StorageFile.GetFileFromPathAsync(scaledPath)).Properties.GetVideoPropertiesAsync();
                if (scaledProperties.Width > 1920 || scaledProperties.Height > 1080) failures.Add("scaled recording exceeds resolution limit");
                VerifyConsole.WriteLine($"PASS recording scale: input={largeItem.Size.Width}x{largeItem.Size.Height}, encoded={scaledProperties.Width}x{scaledProperties.Height}");
            }
            var recoveryStage = captureFiles.CreateStage(); var recoveryPath = Path.Combine(recoveryStage, "recover.png"); await CaptureFiles.WritePngAsync(recoveryPath, crop);
            CaptureFiles.MarkComplete(recoveryStage, [recoveryPath], folder);
            if (await captureFiles.RetryPendingAsync() is not { Saved: 1, Failed: 0 }) failures.Add("capture retry");
            await VerifyPendingFailuresAsync(root, failures);
            VerifyConsole.WriteLine("PASS recording: video-only mode, resize automatic stop/finalize/import, completed capture recovery");
            foreach (var failure in failures) VerifyConsole.WriteLine("FAIL capture: " + failure);
            return failures.Count == 0 ? 0 : 1;
        }
        catch (Exception ex) { VerifyConsole.WriteLine($"FAIL capture: {ex}"); return 1; }
        finally { editor?.Close(); fixture?.Close(); await AssetRecycle.MoveAsync(root); }
    }
    private static async Task VerifyImageEditingAsync(string root, BitmapSource original, BitmapSource edited, List<string> failures)
    {
        using var library = new AssetStore(Path.Combine(root, "edit-library"), AssetRecycle.MoveAsync); await library.Ready;
        var folder = await library.AddCategoryAsync("folder", "編集元"); var tag = await library.AddCategoryAsync("tag", "注釈");
        var file = Path.Combine(root, "edit-source.png"); await CaptureFiles.WritePngAsync(file, original);
        var imported = await library.ImportAsync(file, folder); await library.UpdateAsync([imported.AssetId!], "classify", tag);
        var asset = (await library.GetAsync(imported.AssetId!))!;
        var path = library.ReadOriginalPath(asset); var before = await File.ReadAllBytesAsync(path);
        var decoded = await AssetImageEditor.LoadAsync(library, asset);
        if (!decoded.IsFrozen || decoded.PixelWidth != original.PixelWidth || !ReadPixels(decoded).SequenceEqual(ReadPixels(original))) failures.Add("library full-resolution cross-thread edit image");
        var saved = await AssetImageEditor.SaveCopyAsync(library, asset, edited);
        var copy = (await library.GetAsync(saved.AssetId!))!;
        if (copy.Id == asset.Id || copy.Extension != "png" || !copy.FolderIds.Contains(folder) || !copy.TagIds.Contains(tag)
            || !(await File.ReadAllBytesAsync(path)).SequenceEqual(before)) failures.Add("library edit overwrote original or lost categories");
        var after = await AssetImageEditor.LoadAsync(library, copy);
        if (!ReadPixels(after).SequenceEqual(ReadPixels(edited))) failures.Add("library edit output pixels");
        await library.UpdateAsync([asset.Id], "trash");
        try { await AssetImageEditor.LoadAsync(library, (await library.GetAsync(asset.Id))!); failures.Add("trashed asset accepted for editing"); } catch (InvalidOperationException) { }
        VerifyConsole.WriteLine("PASS image editing: original bytes retained, full-resolution frozen pixels, edited PNG readback, folders/tags, trash guard");
    }
    private static async Task VerifyPendingFailuresAsync(string root, List<string> failures)
    {
        using var store = new AssetStore(Path.Combine(root, "pending-regressions"), AssetRecycle.MoveAsync);
        await store.Ready; var files = new CaptureFiles(store); var blocked = new List<string>();
        foreach (var marker in new[] { "{broken", "{}", "{\"Files\":null}", "{\"Files\":[null]}" })
        {
            var stage = files.CreateStage(); blocked.Add(stage);
            await File.WriteAllTextAsync(Path.Combine(stage, "complete.json"), marker);
            await File.WriteAllBytesAsync(Path.Combine(stage, "preserved.png"), [1, 2, 3]);
        }
        var good = files.CreateStage(); await File.WriteAllBytesAsync(Path.Combine(good, "good.png"), [4, 5, 6]);
        CaptureFiles.MarkComplete(good, ["good.png"], null);
        var result = await files.RetryPendingAsync();
        if (result is not { Saved: 1, Failed: 4 } || result.Error is null || (await store.QueryAsync(new())).Total != 1
            || blocked.Any(stage => !File.Exists(Path.Combine(stage, "preserved.png")))) failures.Add("corrupt pending records blocked healthy capture or lost failure files");
        var source = Path.Combine(root, "duplicate-pending.png"); await File.WriteAllBytesAsync(source, [7, 8, 9]);
        var first = await store.ImportAsync(source); var asset = (await store.GetAsync(first.AssetId!))!;
        File.Move(store.OriginalPath(asset), Path.Combine(root, "preserved-pending-original.png"));
        var missing = files.CreateStage(); File.Copy(source, Path.Combine(missing, "same.png")); CaptureFiles.MarkComplete(missing, ["same.png"], null);
        var trashed = (await store.QueryAsync(new())).Items.First(item => item.Id != asset.Id);
        await store.UpdateAsync([trashed.Id], "trash");
        var trash = files.CreateStage(); await File.WriteAllBytesAsync(Path.Combine(trash, "trash.png"), [4, 5, 6]); CaptureFiles.MarkComplete(trash, ["trash.png"], null);
        var next = files.CreateStage(); await File.WriteAllBytesAsync(Path.Combine(next, "next.png"), [10, 11, 12]); CaptureFiles.MarkComplete(next, ["next.png"], null);
        result = await files.RetryPendingAsync();
        if (result is not { Saved: 1, Failed: 6 } || !File.Exists(Path.Combine(missing, "same.png")) || !File.Exists(Path.Combine(trash, "trash.png"))
            || File.Exists(store.OriginalPath(asset)) || (await store.QueryAsync(new())).Total != 2)
            failures.Add("missing/trash original reported saved, replaced original, or blocked later healthy capture");
        VerifyConsole.WriteLine("PASS capture pending: malformed/null records, missing original and trash duplicate retained; healthy captures continue");
    }
    private static byte[] ReadPixels(BitmapSource bitmap)
    { var converted = new FormatConvertedBitmap(bitmap, PixelFormats.Bgra32, null, 0); var data = new byte[converted.PixelWidth * converted.PixelHeight * 4]; converted.CopyPixels(data, converted.PixelWidth * 4, 0); return data; }
    private static async Task VerifyVideoOrientationAsync(string path, string label, List<string> failures)
    {
        var clip = await global::Windows.Media.Editing.MediaClip.CreateFromFileAsync(await StorageFile.GetFileFromPathAsync(path));
        var composition = new global::Windows.Media.Editing.MediaComposition(); composition.Clips.Add(clip);
        using var thumbnail = await composition.GetThumbnailAsync(TimeSpan.FromMilliseconds(200), 640, 400, global::Windows.Media.Editing.VideoFramePrecision.NearestFrame);
        using var stream = thumbnail.AsStreamForRead();
        var image = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
        var bytes = ReadPixels(image);
        var expected = new[] { (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0) };
        var correct = true;
        for (var i = 0; i < 4; i++)
        {
            var x = image.PixelWidth * (i % 2 == 0 ? 1 : 3) / 4;
            var y = image.PixelHeight * (i < 2 ? 1 : 3) / 4;
            var offset = (y * image.PixelWidth + x) * 4; var color = expected[i];
            correct &= Math.Abs(bytes[offset + 2] - color.Item1) < 90 && Math.Abs(bytes[offset + 1] - color.Item2) < 90 && Math.Abs(bytes[offset] - color.Item3) < 90;
        }
        if (Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG") is { Length: > 0 } log)
        {
            var evidence = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(log))!, Path.GetFileNameWithoutExtension(log) + "-media");
            Directory.CreateDirectory(evidence);
            File.Copy(path, Path.Combine(evidence, $"orientation-{label}.mp4"), true);
            var detached = BitmapSource.Create(image.PixelWidth, image.PixelHeight, 96, 96, PixelFormats.Bgra32, null, bytes, image.PixelWidth * 4); detached.Freeze();
            await CaptureFiles.WritePngAsync(Path.Combine(evidence, $"orientation-{label}.png"), detached);
        }
        if (!correct) failures.Add($"recording {label}: decoded MP4 quadrant orientation is incorrect");
        VerifyConsole.WriteLine($"{(correct ? "PASS" : "FAIL")} recording orientation: mode={label}, decoded_four_quadrants={correct}");
    }
    [DllImport("user32.dll")] private static extern bool IsWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint hwnd);
    private delegate bool EnumWindowCallback(nint hwnd, nint data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowCallback callback, nint data);
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint hwnd, uint flags);
    [DllImport("user32.dll")] private static extern bool PostMessage(nint hwnd, uint message, nint wparam, nint lparam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(nint hwnd, System.Text.StringBuilder title, int count);
    [DllImport("user32.dll")] private static extern nint SendMessage(nint hwnd, uint message, nint wparam, nint lparam);
    private static ScreenshotSelectionWindow SelectSnapshot(BitmapSource snapshot, System.Drawing.Rectangle bounds, Action<ScreenshotSelectionWindow> interact)
    {
        var selection = new ScreenshotSelectionWindow(snapshot, bounds);
        Exception? error = null;
        selection.Loaded += (_, _) => selection.Dispatcher.BeginInvoke(new Action(() =>
        {
            try { interact(selection); }
            catch (Exception ex) { error = ex; selection.Close(); }
        }), System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        selection.ShowDialog();
        if (error is not null) throw new InvalidOperationException("Screenshot selection verification failed.", error);
        return selection;
    }
    private static void SelectionKey(Window window, System.Windows.Input.Key key) => window.RaiseEvent(new System.Windows.Input.KeyEventArgs(
        System.Windows.Input.Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, key) { RoutedEvent = System.Windows.Input.Keyboard.KeyDownEvent });
    [StructLayout(LayoutKind.Sequential)] private struct CursorPoint { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out CursorPoint point);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [StructLayout(LayoutKind.Sequential)] private struct WindowRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint hwnd, out WindowRect rect);
    private sealed class DisposableWindow(Window window) : IDisposable { public Window Window => window; public void Dispose() => window.Close(); }
}
