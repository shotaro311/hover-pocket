using System.Runtime.InteropServices;
using System.Text;
using HoverPocket.Assets;
using HoverPocket.Shell.Providers.Controls;
using Windows.Graphics.Capture;

namespace HoverPocket.Shell.Capture;

internal sealed record VoiceCaptureTarget(string Id, string Title, nint Handle, uint ProcessId, bool Monitor, DateTimeOffset ExpiresAt);

internal sealed class VoiceCaptureTargets : IDisposable
{
    private readonly Dictionary<string, VoiceCaptureTarget> _targets = [];
    private readonly WinEventCallback _callback;
    private readonly nint _hook;
    private readonly bool _allowOwnWindowsForVerify;
    private nint _lastExternal;

    public VoiceCaptureTargets(bool allowOwnWindowsForVerify = false)
    {
        _allowOwnWindowsForVerify = allowOwnWindowsForVerify;
        Remember(GetForegroundWindow());
        _callback = (_, _, window, _, _, _, _) => Remember(window);
        _hook = SetWinEventHook(3, 3, 0, _callback, 0, 0, 0);
    }

    private void Remember(nint window)
    {
        GetWindowThreadProcessId(window, out var pid);
        if (window != 0 && (pid != Environment.ProcessId || _allowOwnWindowsForVerify)) _lastExternal = window;
    }

    public IReadOnlyList<VoiceCaptureTarget> List(string query = "")
    {
        Prune();
        var result = new List<VoiceCaptureTarget>();
        var normalized = AssetFormat.Normalize(query);
        EnumWindows((window, _) =>
        {
            if (!Eligible(window)) return true;
            var title = Title(window);
            if (title.Length == 0 || !AssetFormat.Normalize(title).Contains(normalized, StringComparison.Ordinal)) return true;
            result.Add(Bind(window, false));
            return result.Count < 40;
        }, 0);
        return result;
    }

    public VoiceCaptureTarget Resolve(string target, string? windowId, string? windowTitle)
    {
        Prune();
        Remember(GetForegroundWindow());
        if (target == "window")
        {
            if (!string.IsNullOrEmpty(windowId))
            {
                var selected = Get(windowId);
                if (selected.Monitor || (windowTitle is not null && !AssetFormat.Normalize(selected.Title).Contains(AssetFormat.Normalize(windowTitle), StringComparison.Ordinal)))
                    throw new ArgumentException("capture_target_invalid");
                return selected;
            }
            if (string.IsNullOrWhiteSpace(windowTitle)) throw new InvalidOperationException("window_title_required");
            var matches = List(windowTitle);
            var exact = matches.Where(item => AssetFormat.Normalize(item.Title) == AssetFormat.Normalize(windowTitle)).ToArray();
            if (exact.Length == 1) return exact[0];
            if (matches.Count == 1) return matches[0];
            throw new InvalidOperationException(matches.Count == 0 ? "window_not_found" : "window_ambiguous_use_windows_list");
        }
        if (windowId is not null || windowTitle is not null) throw new ArgumentException("unexpected_window_selector");
        if (target == "current_window")
        {
            if (!Eligible(_lastExternal)) throw new InvalidOperationException("current_window_unavailable");
            return Bind(_lastExternal, false);
        }
        if (target != "screen") throw new ArgumentException("capture_target_invalid");
        var monitor = MonitorFromWindow(_lastExternal, 2);
        if (monitor == 0) throw new InvalidOperationException("screen_unavailable");
        return Bind(monitor, true);
    }

    private VoiceCaptureTarget Bind(nint handle, bool monitor)
    {
        GetWindowThreadProcessId(handle, out var pid);
        var title = monitor ? "現在のウィンドウがある画面全体" : Title(handle);
        var existing = _targets.Values.FirstOrDefault(item => item.Handle == handle && item.Monitor == monitor && item.Title == title && item.ProcessId == pid);
        if (existing is not null) return existing;
        if (_targets.Count >= 256) throw new InvalidOperationException("too_many_capture_targets");
        var value = new VoiceCaptureTarget(Guid.NewGuid().ToString("N"), title, handle, pid, monitor, DateTimeOffset.UtcNow.AddMinutes(3));
        _targets.Add(value.Id, value);
        return value;
    }

    public VoiceCaptureTarget Get(string id)
    {
        if (!_targets.TryGetValue(id, out var target) || target.ExpiresAt <= DateTimeOffset.UtcNow)
            throw new InvalidOperationException("capture_target_expired");
        if (!target.Monitor)
        {
            GetWindowThreadProcessId(target.Handle, out var pid);
            if (!Eligible(target.Handle) || pid != target.ProcessId || Title(target.Handle) != target.Title)
                throw new InvalidOperationException("capture_target_changed");
        }
        return target;
    }

    public GraphicsCaptureItem CaptureItem(string id)
    {
        var target = Get(id);
        return target.Monitor ? WindowsGraphicsCapturePreviewService.CreateCaptureItemForMonitor(target.Handle)
            : WindowsGraphicsCapturePreviewService.CreateCaptureItemForWindow(target.Handle);
    }

    private bool Eligible(nint window)
    {
        if (window == 0 || !IsWindowVisible(window) || IsIconic(window)) return false;
        GetWindowThreadProcessId(window, out var pid);
        if (!_allowOwnWindowsForVerify && pid == Environment.ProcessId) return false;
        if (DwmGetWindowAttribute(window, 14, out var cloaked, sizeof(int)) == 0 && cloaked != 0) return false;
        var name = new StringBuilder(128); GetClassName(window, name, name.Capacity);
        return name.ToString() is not ("Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd") && Title(window).Length > 0;
    }

    private static string Title(nint window) { var text = new StringBuilder(513); GetWindowText(window, text, text.Capacity); return text.ToString(); }
    private void Prune() { foreach (var entry in _targets.Where(item => item.Value.ExpiresAt <= DateTimeOffset.UtcNow).ToArray()) _targets.Remove(entry.Key); }
    public void Dispose() { if (_hook != 0) UnhookWinEvent(_hook); _targets.Clear(); }

    private delegate void WinEventCallback(nint hook, uint type, nint window, int objectId, int childId, uint thread, uint time);
    private delegate bool EnumCallback(nint window, nint data);
    [DllImport("user32.dll")] private static extern nint SetWinEventHook(uint min, uint max, nint module, WinEventCallback callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(nint hook);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumCallback callback, nint data);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern bool IsIconic(nint window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(nint window, StringBuilder text, int size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(nint window, StringBuilder text, int size);
    [DllImport("user32.dll")] private static extern nint MonitorFromWindow(nint window, uint flags);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint window, uint attribute, out int value, int size);
}
