using System.Runtime.InteropServices;
using System.Windows.Input;
using System.Windows.Interop;

namespace HoverPocket.Shell.Capture;

internal sealed class CaptureHotkeys : IDisposable
{
    private readonly HwndSource _source;
    private readonly Action<string> _action;
    private bool _suspended;
    private Dictionary<int, string> _actions = [];
    private Dictionary<string, string> _bindings = [];
    private readonly HashSet<int> _registered = [];
    public CaptureHotkeys(Action<bool> action) : this((string key) => action(key == "recording"), true) { }
    public CaptureHotkeys(Action<string> action, bool named)
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
        var bindings = new Dictionary<string, string> { ["screenshot"] = screenshot, ["recording"] = recording };
        ValidateBindings(bindings);
        try { return ApplyBindings(bindings); } catch (ArgumentException ex) { return ex.Message; }
    }
    internal static void ValidateBindings(Dictionary<string, string> bindings)
    {
        var values = bindings.Values.Where(value => !string.IsNullOrWhiteSpace(value)).Select(Parse).ToArray();
        if (values.Distinct().Count() != values.Length) throw new ArgumentException("同じキーを複数の操作へ設定できません。");
    }
    internal string ApplyBindings(Dictionary<string, string> bindings)
    {
        ValidateBindings(bindings);
        var prior = new Dictionary<string, string>(_bindings);
        var conflicts = RegisterBindings(bindings);
        if (conflicts.Count > 0)
        {
            RegisterBindings(prior);
            throw new ArgumentException("他のアプリが使用中: " + string.Join(" / ", conflicts) + "。以前の設定を保持しました。");
        }
        _bindings = new(bindings);
        return "ショートカットは有効です。";
    }
    private List<string> RegisterBindings(Dictionary<string, string> bindings)
    {
        foreach (var id in _registered) UnregisterHotKey(_source.Handle, id);
        _registered.Clear(); _actions.Clear();
        var conflicts = new List<string>(); var index = 0;
        if (_suspended) return conflicts;
        foreach (var (action, key) in bindings)
        {
            if (string.IsNullOrWhiteSpace(key)) continue;
            var id = ++index; var value = Parse(key);
            if (RegisterHotKey(_source.Handle, id, value.Modifiers, value.Key)) { _registered.Add(id); _actions[id] = action; }
            else conflicts.Add(key);
        }
        return conflicts;
    }
    internal void Suspend(bool suspended)
    {
        _suspended = suspended;
        if (suspended) { foreach (var id in _registered) UnregisterHotKey(_source.Handle, id); _registered.Clear(); }
        else ApplyBindings(_bindings);
    }
    private nint Hook(nint hwnd, int message, nint wparam, nint lparam, ref bool handled)
    { if (message == 0x0312 && _registered.Contains((int)wparam)) { handled = true; _action(_actions[(int)wparam]); } return 0; }
    internal nint HandleForVerify => _source.Handle;
    public void Dispose() { foreach (var id in _registered) UnregisterHotKey(_source.Handle, id); _registered.Clear(); _source.RemoveHook(Hook); _source.Dispose(); }
    [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(nint hwnd, int id);
}
