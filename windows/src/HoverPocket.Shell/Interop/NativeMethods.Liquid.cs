using System.Runtime.InteropServices;
using System.Windows.Media;

namespace HoverPocket.Shell.Interop;

internal static partial class NativeMethods
{
    public static void SetEmptyWindowRegion(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        var region = CreateRectRgn(0, 0, 0, 0);
        if (region == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        if (SetWindowRgn(hwnd, region, true) == 0)
        {
            DeleteObject(region);
            throw new System.ComponentModel.Win32Exception();
        }
    }

    public static void SetLiquidWindowRegion(IntPtr hwnd, Geometry geometry, double scaleX, double scaleY)
    {
        if (hwnd == IntPtr.Zero) return;
        var flattened = geometry.GetFlattenedPathGeometry(.15 / Math.Max(scaleX, scaleY), ToleranceType.Absolute);
        var points = new List<RegionPoint>();
        foreach (var figure in flattened.Figures)
        {
            Add(figure.StartPoint);
            foreach (var segment in figure.Segments)
            {
                if (segment is PolyLineSegment poly) foreach (var point in poly.Points) Add(point);
                else if (segment is LineSegment line) Add(line.Point);
            }
        }
        var region = CreatePolygonRgn(points.ToArray(), points.Count, 2);
        if (region == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        // On success Windows owns HRGN. On failure it remains ours.
        if (SetWindowRgn(hwnd, region, true) == 0)
        {
            DeleteObject(region);
            throw new System.ComponentModel.Win32Exception();
        }
        void Add(System.Windows.Point point) => points.Add(new RegionPoint
        {
            X = (int)Math.Round(point.X * scaleX), Y = (int)Math.Round(point.Y * scaleY)
        });
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct RegionPoint { public int X; public int Y; }
    internal static IntPtr LiquidWindowAtPoint(int x, int y) => GetAncestor(
        WindowFromPoint(new RegionPoint { X = x, Y = y }), 2);
    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(RegionPoint point);
    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    internal static bool LiquidRegionContains(IntPtr hwnd, int x, int y)
    {
        var region = CreateRectRgn(0, 0, 0, 0);
        try { return GetWindowRgn(hwnd, region) > 0 && PtInRegion(region, x, y); }
        finally { DeleteObject(region); }
    }
    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateRectRgn(int left, int top, int right, int bottom);
    [DllImport("user32.dll")]
    private static extern int GetWindowRgn(IntPtr hwnd, IntPtr region);
    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PtInRegion(IntPtr region, int x, int y);
    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern IntPtr CreatePolygonRgn([In] RegionPoint[] points, int count, int mode);
    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(IntPtr handle);
}
