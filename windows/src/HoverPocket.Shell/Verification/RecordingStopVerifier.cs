using System.Text.Json;
using System.Windows;
using System.Windows.Interop;
using HoverPocket.Assets;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Capture;
using HoverPocket.Shell.Providers.Assets;
using HoverPocket.Shell.Providers.Controls;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell.Verification;

/// <summary>
/// While a screen recording runs, the open panel shows a stop button in its header. Pressing it stops the
/// recording and saves it to the library, and the button leaves the tool icons where they were.
/// </summary>
internal static class RecordingStopVerifier
{
    public static async Task<int> RunAsync(HoverShellController controller)
    {
        var failures = new List<string>();
        var root = Path.Combine(Path.GetTempPath(), "HoverPocket", "RecordingStopVerify", Guid.NewGuid().ToString("N"));
        var bridge = controller.PanelBridgeController;
        var previous = bridge.VoiceCapture;
        var web = controller.Panel.WebView!;
        var fixture = new Window
        {
            Title = "HoverPocket recording stop verification (generated content)", Width = 480, Height = 300,
            WindowStartupLocation = WindowStartupLocation.CenterScreen, ShowActivated = false,
            Content = new System.Windows.Controls.Border { Background = System.Windows.Media.Brushes.SteelBlue }
        };
        async Task<string> Js(string expression) => await web.ExecuteScriptAsync(expression);
        async Task Until(Func<Task<bool>> ready, string label)
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (!await ready())
            {
                if (DateTime.UtcNow > deadline) throw new TimeoutException(label);
                await Task.Delay(50);
            }
        }
        bool PanelRecording() => JsonSerializer.SerializeToElement(bridge.BuildState(BridgeSurface.Panel))
            .GetProperty("capture").GetProperty("recording").GetBoolean();
        const string headerRects = """
            [...document.querySelectorAll('[data-provider-icons] button, [data-chat], [data-refresh], [data-settings]')]
                .map(n => { const r = n.getBoundingClientRect(); return [r.left, r.top].map(v => v.toFixed(2)).join(':'); }).join('|')
            """;
        try
        {
            using var store = new AssetStore(root, AssetRecycle.MoveAsync);
            await store.Ready;
            using var capture = new CaptureController(store, Path.Combine(root, "capture"), () => Task.CompletedTask, () => { }, () => { });
            capture.SavePreferences(new("Ctrl+Alt+F21", "Ctrl+Alt+F22", false, false, null, false));
            bridge.VoiceCapture = capture;
            fixture.Show();
            var item = WindowsGraphicsCapturePreviewService.CreateCaptureItemForWindow(new WindowInteropHelper(fixture).Handle);

            if (PanelRecording() || await Js("document.querySelector('[data-record-stop]').hidden") != "true")
                failures.Add("recording stop: button shown before a recording starts");
            var before = await Js(headerRects);

            await capture.ToggleRecordingAsync(_ => Task.FromResult<global::Windows.Graphics.Capture.GraphicsCaptureItem?>(item));
            if (!capture.Recording || !PanelRecording()) failures.Add("recording stop: panel state does not report the running recording");
            await Until(async () => await Js("""
                (() => { const b = document.querySelector('[data-record-stop]');
                  return !b.hidden && !b.disabled && b.textContent === '録画を停止' && getComputedStyle(b).display !== 'none'; })()
                """) == "true", "recording stop: header button did not appear while recording");
            if (await Js(headerRects) != before) failures.Add("recording stop: the stop button moved the tool icons");
            if (Environment.GetEnvironmentVariable("HOVERPOCKET_RECORDING_STOP_SNAPSHOT_DIR") is { Length: > 0 } folder)
            {
                Directory.CreateDirectory(folder);
                await using var png = File.Create(Path.Combine(folder, "recording-stop-header.png"));
                await web.CoreWebView2.CapturePreviewAsync(Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat.Png, png);
            }
            // The smallest panel (520 px wide) has the least header room: the button shrinks to an icon there.
            await Js($$"""
                window.__recordStopSmall = null;
                (async () => {
                  const html = document.documentElement, button = document.querySelector('[data-record-stop]');
                  const header = document.querySelector('.hp-header'), size = html.dataset.panelSize;
                  header.style.boxSizing = 'border-box'; header.style.width = '520px'; html.dataset.panelSize = 'small';
                  await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
                  const shown = {{headerRects}};
                  button.hidden = true; const hidden = {{headerRects}}; button.hidden = false;
                  const inside = node => { const r = node.getBoundingClientRect(), h = header.getBoundingClientRect();
                    return r.width > 0 && r.left >= h.left - 0.5 && r.right <= h.right + 0.5; };
                  let result = shown === hidden
                    && Math.round(button.getBoundingClientRect().width) === 28
                    && getComputedStyle(button.querySelector('.hp-record-stop-label')).display === 'none'
                    && getComputedStyle(document.querySelector('[data-provider-title]')).display === 'none'
                    && button.getAttribute('aria-label') === '録画を停止'
                    && header.scrollWidth <= header.clientWidth;
                  // Generated tools can add icons: with four more, stop and settings must both stay in the header.
                  const nav = document.querySelector('[data-provider-icons]');
                  const extra = [...nav.children].slice(0, 4).map(n => { const c = n.cloneNode(true); c.dataset.providerId = 'verify-extra'; nav.append(c); return c; });
                  await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
                  result = result && inside(button) && inside(document.querySelector('[data-settings]'));
                  extra.forEach(n => n.remove());
                  header.style.boxSizing = header.style.width = ''; html.dataset.panelSize = size;
                  await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
                  window.__recordStopSmall = result;
                })()
                """);
            await Until(async () => await Js("window.__recordStopSmall !== null") == "true", "recording stop: smallest-panel check did not finish");
            if (await Js("window.__recordStopSmall") != "true") failures.Add("recording stop: the smallest panel does not fit the icon-only stop button without moving the icons");
            if (await Js("document.querySelector('[data-record-stop]').closest('.hp-header') !== null") != "true")
                failures.Add("recording stop: button is not in the panel header");

            await Task.Delay(800);
            await Js("document.querySelector('[data-record-stop]').click()");
            await Until(() => Task.FromResult(!capture.Recording && !capture.Busy), "recording stop: header button did not stop the recording");
            await Until(async () => await Js("document.querySelector('[data-record-stop]').hidden") == "true",
                "recording stop: button stayed after the recording was saved");
            var saved = await store.QueryAsync(new());
            if (saved.Items.Count(asset => asset.Kind == "video") != 1) failures.Add("recording stop: stopping from the panel did not save one video");
            if (PanelRecording()) failures.Add("recording stop: panel state still reports recording");

            // Region recording captures the whole monitor: the panel and any window created meanwhile stay out of it.
            var panelHandle = controller.Panel.Hwnd;
            GetWindowDisplayAffinity(panelHandle, out var panelAffinity);
            ProbeWindow? late = null, selfExcluded = null;
            Window? plain = null;
            nint plainHandle = 0;
            using (new CaptureWindowExclusion())
            {
                late = new ProbeWindow();
                late.EnsureHandle();
                plain = new Window { Title = "HoverPocket plain window probe", Width = 40, Height = 40, Left = -20000, Top = -20000, ShowActivated = false, ShowInTaskbar = false, WindowStyle = WindowStyle.None };
                var loaded = new TaskCompletionSource();
                plain.Loaded += (_, _) => loaded.TrySetResult();
                plain.Show();
                plainHandle = new WindowInteropHelper(plain).Handle;
                await loaded.Task.WaitAsync(TimeSpan.FromSeconds(5));
                // A toast excludes itself for good; the recording's exclusion must not undo that.
                selfExcluded = new ProbeWindow();
                selfExcluded.EnsureHandle();
                CaptureController.ExcludeFromCapture(selfExcluded.Hwnd);
                if (!Affinity(panelHandle, 0x11)) failures.Add("recording stop: the panel is not kept out of the capture");
                if (!Affinity(late.Hwnd, 0x11)) failures.Add("recording stop: a panel-type window created during recording is not kept out of the capture");
                if (!Affinity(plainHandle, 0x11)) failures.Add("recording stop: a plain window opened during recording is not kept out of the capture");
            }
            if (!Affinity(panelHandle, panelAffinity) || !Affinity(late.Hwnd, 0) || !Affinity(plainHandle, 0))
                failures.Add("recording stop: capture exclusion was not undone after recording");
            if (!Affinity(selfExcluded.Hwnd, 0x11)) failures.Add("recording stop: a window's own capture exclusion was undone by the recording");
            late.Close(); plain.Close(); selfExcluded.Close();
        }
        catch (Exception exception)
        {
            failures.Add($"recording stop: {exception.GetType().Name}: {exception.Message}");
        }
        finally
        {
            bridge.VoiceCapture = previous;
            fixture.Close();
            try { Directory.Delete(root, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }

        if (failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS recording stop: header button appears while recording, keeps the icons in place, stops and saves, then hides");
            return 0;
        }
        VerifyConsole.WriteLine("FAIL recording stop verify:");
        foreach (var failure in failures) VerifyConsole.WriteLine("- " + failure);
        return 1;
    }

    private sealed class ProbeWindow : NoActivateWindow
    {
        public ProbeWindow() { Title = "HoverPocket capture exclusion probe"; Width = Height = 40; Left = Top = -20000; }
    }

    private static bool Affinity(nint window, uint expected) => GetWindowDisplayAffinity(window, out var affinity) && affinity == expected;
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool GetWindowDisplayAffinity(nint window, out uint affinity);
}
