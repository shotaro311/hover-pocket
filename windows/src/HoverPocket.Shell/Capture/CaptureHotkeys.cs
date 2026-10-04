using System.Runtime.InteropServices;
using System.Windows.Input;
using System.Windows.Interop;

namespace HoverPocket.Shell.Capture;

internal sealed class CaptureHotkeys : IDisposable
{
    private readonly HwndSource _source;
    private readonly Action<bool> _action;
    private readonly HashSet<int> _registered = [];
    public CaptureHotkeys(Action<bool> action)
    {
        _action = action; _source = new HwndSource(new HwndSourceParameters("HoverPocket capture shortcuts") { ParentWindow = new nint(-3), Width = 0, Height = 0, WindowStyle = 0 }); _source.AddHook(Hook);
    }
    internal static (uint Modifiers, uint Key) Parse(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) throw new ArgumentException("ショートカットを入力してください。");
        var parts = value.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries); uint modifiers = 0;
        if (parts.Length < 2) throw new ArgumentException("CtrlまたはAltと、キーを組み合わせてください。");
        foreach (var part in parts[..^1]) modifiers |= part.ToLowerInvariant() switch { "ctrl" => 2u, "alt" => 1u, "shift" => 4u, "win" => 8u, _ => throw new ArgumentException("修飾キーはCtrl / Alt / Shift / Winです。") };
        Key key;
        try { key = (Key)new KeyConverter().ConvertFromInvariantString(parts[^1])!; }
        catch (Exception ex) when (ex is NotSupportedException or FormatException) { throw new ArgumentException("キーの名前を確認してください（例: Ctrl+Alt+S）。"); }
        if (key is Key.None or Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift || (modifiers & 3) == 0) throw new ArgumentException("CtrlまたはAltと、文字・数字・Fキーを組み合わせてください。");
        return (modifiers | 0x4000, (uint)KeyInterop.VirtualKeyFromKey(key));
    }
    public string Apply(string screenshot, string recording)
    {
        var first = Parse(screenshot); var second = Parse(recording); if (first == second) throw new ArgumentException("撮影と収録には別のショートカットを指定してください。");
        foreach (var id in _registered) UnregisterHotKey(_source.Handle, id); _registered.Clear();
        var conflicts = new List<string>();
        Register(1, first, screenshot); Register(2, second, recording);
        return conflicts.Count == 0 ? "ショートカットは有効です。" : "他のアプリが使用中: " + string.Join(" / ", conflicts) + "。別のキーへ変更するか、画面・トレイのボタンを使ってください。";
        void Register(int id, (uint Modifiers, uint Key) value, string label) { if (RegisterHotKey(_source.Handle, id, value.Modifiers, value.Key)) _registered.Add(id); else conflicts.Add(label); }
    }
    private nint Hook(nint hwnd, int message, nint wparam, nint lparam, ref bool handled)
    { if (message == 0x0312 && _registered.Contains((int)wparam)) { handled = true; _action((int)wparam == 2); } return 0; }
    internal nint HandleForVerify => _source.Handle;
    public void Dispose() { foreach (var id in _registered) UnregisterHotKey(_source.Handle, id); _registered.Clear(); _source.RemoveHook(Hook); _source.Dispose(); }
    [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(nint hwnd, int id);
}
