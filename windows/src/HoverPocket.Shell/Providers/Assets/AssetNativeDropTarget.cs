using System.Runtime.InteropServices;
using IDataObject = System.Runtime.InteropServices.ComTypes.IDataObject;

namespace HoverPocket.Shell.Providers.Assets;

[StructLayout(LayoutKind.Sequential)] internal struct AssetDragPoint { public int X, Y; }
[ComVisible(true), Guid("00000122-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAssetOleDropTarget
{
    [PreserveSig] int DragEnter([MarshalAs(UnmanagedType.Interface)] IDataObject data, uint keys, AssetDragPoint point, ref uint effect);
    [PreserveSig] int DragOver(uint keys, AssetDragPoint point, ref uint effect);
    [PreserveSig] int DragLeave();
    [PreserveSig] int Drop([MarshalAs(UnmanagedType.Interface)] IDataObject data, uint keys, AssetDragPoint point, ref uint effect);
}

[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
internal sealed class AssetNativeDropTarget : IAssetOleDropTarget, IDisposable
{
    private readonly nint _handle;
    private readonly Func<AssetDragPoint, bool> _hover;
    private readonly Action _leave;
    private readonly Action<System.Windows.IDataObject, IDataObject, AssetDragPoint> _drop;
    private readonly Action<Exception> _error;
    private bool _accepted;
    internal string Trace { get; private set; } = "not entered";
    internal AssetNativeDropTarget(nint handle, Func<AssetDragPoint, bool> hover, Action leave, Action<System.Windows.IDataObject, IDataObject, AssetDragPoint> drop, Action<Exception> error)
    {
        _handle = handle; _hover = hover; _leave = leave; _drop = drop; _error = error;
        // WPF registers its HWND even when AllowDrop is false. This dedicated overlay owns the replacement.
        RevokeDragDrop(handle);
        Marshal.ThrowExceptionForHR(RegisterDragDrop(handle, this));
    }
    public int DragEnter(IDataObject data, uint keys, AssetDragPoint point, ref uint effect)
    {
        try { var wrapped = new System.Windows.DataObject(data); _accepted = AssetDropPayload.Supports(wrapped); Trace = $"enter accepted={_accepted}; formats={string.Join(',', wrapped.GetFormats(false))}"; effect = _accepted && _hover(point) ? effect & 1u : 0; }
        catch (Exception ex) { Trace = "enter failed: " + ex; _accepted = false; effect = 0; }
        return 0;
    }
    public int DragOver(uint keys, AssetDragPoint point, ref uint effect) { try { effect = _accepted && _hover(point) ? effect & 1u : 0; } catch { effect = 0; } return 0; }
    public int DragLeave() { _accepted = false; _leave(); return 0; }
    public int Drop(IDataObject data, uint keys, AssetDragPoint point, ref uint effect)
    {
        try { if (_accepted && _hover(point)) { Trace += "; drop"; _drop(new System.Windows.DataObject(data), data, point); effect &= 1; } else effect = 0; }
        catch (Exception ex) { effect = 0; _error(ex); }
        _accepted = false; return 0;
    }
    public void Dispose() => RevokeDragDrop(_handle);
    [DllImport("ole32.dll")] private static extern int RegisterDragDrop(nint hwnd, [MarshalAs(UnmanagedType.Interface)] IAssetOleDropTarget target);
    [DllImport("ole32.dll")] private static extern int RevokeDragDrop(nint hwnd);
}
