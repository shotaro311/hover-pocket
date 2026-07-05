using System.Runtime.InteropServices;
using System.IO;

namespace HoverPocket.Shell.Interop;

internal static partial class NativeMethods
{
    public const int GwlExStyle = -20;
    public const int WmMouseActivate = 0x0021;
    public const int WmDisplayChange = 0x007E;
    public const int WmDpiChanged = 0x02E0;
    public const int MaNoActivate = 3;

    public const long WsExTopmost = 0x00000008L;
    public const long WsExToolWindow = 0x00000080L;
    public const long WsExNoActivate = 0x08000000L;

    private const uint MonitorinfofPrimary = 0x00000001;
    private const int SwShownoactivate = 4;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpShowWindow = 0x0040;
    private static readonly IntPtr HwndTopmost = new(-1);

    public static void AddExtendedStyles(IntPtr hwnd, long styles)
    {
        var current = GetWindowLongPtr(hwnd, GwlExStyle).ToInt64();
        _ = SetWindowLongPtr(hwnd, GwlExStyle, new IntPtr(current | styles));
    }

    public static long GetExtendedStyles(IntPtr hwnd)
    {
        return GetWindowLongPtr(hwnd, GwlExStyle).ToInt64();
    }

    public static void SetTopmostNoActivate(IntPtr hwnd)
    {
        _ = SetWindowPos(hwnd, HwndTopmost, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoActivate);
    }

    public static void SetWindowBoundsNoActivate(IntPtr hwnd, int x, int y, int width, int height, bool show)
    {
        var flags = SwpNoActivate;
        if (show)
        {
            flags |= SwpShowWindow;
        }

        _ = SetWindowPos(hwnd, HwndTopmost, x, y, width, height, flags);
    }

    public static void ShowNoActivate(IntPtr hwnd)
    {
        _ = ShowWindow(hwnd, SwShownoactivate);
        _ = SetWindowPos(hwnd, HwndTopmost, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoActivate | SwpShowWindow);
    }

    public static bool TryGetWindowRect(IntPtr hwnd, out NativeRect rect)
    {
        return GetWindowRect(hwnd, out rect);
    }

    public static int CountTopLevelWindowsForCurrentProcess()
    {
        var currentProcessId = Environment.ProcessId;
        var count = 0;

        EnumWindows((hwnd, lParam) =>
        {
            _ = lParam;
            GetWindowThreadProcessId(hwnd, out var processId);
            if (processId == currentProcessId)
            {
                count++;
            }

            return true;
        }, IntPtr.Zero);

        return count;
    }

    public static double GetScaleForWindow(IntPtr hwnd)
    {
        var dpi = GetDpiForWindow(hwnd);
        return dpi == 0 ? 1.0 : dpi / 96.0;
    }

    public static IReadOnlyList<NativeDisplayMonitor> EnumerateDisplayMonitors()
    {
        var monitors = new List<NativeDisplayMonitor>();
        MonitorEnumProc callback = (hMonitor, hdcMonitor, lprcMonitor, lParam) =>
        {
            _ = hdcMonitor;
            _ = lprcMonitor;
            _ = lParam;

            var monitorInfo = new MonitorInfo
            {
                Size = Marshal.SizeOf<MonitorInfo>()
            };

            if (!GetMonitorInfo(hMonitor, ref monitorInfo))
            {
                return true;
            }

            var dpiX = 96U;
            var dpiY = 96U;
            _ = GetDpiForMonitor(hMonitor, MonitorDpiType.Effective, out dpiX, out dpiY);

            monitors.Add(new NativeDisplayMonitor(
                hMonitor,
                monitorInfo.Monitor,
                monitorInfo.WorkArea,
                (monitorInfo.Flags & MonitorinfofPrimary) == MonitorinfofPrimary,
                dpiX == 0 ? 96 : dpiX,
                dpiY == 0 ? 96 : dpiY));

            return true;
        };

        _ = EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
        return monitors;
    }

    public static void AttachParentConsole()
    {
        const uint attachParentProcess = 0xFFFFFFFF;
        if (!AttachConsole(attachParentProcess))
        {
            return;
        }

        var standardOutput = new StreamWriter(Console.OpenStandardOutput())
        {
            AutoFlush = true
        };
        var standardError = new StreamWriter(Console.OpenStandardError())
        {
            AutoFlush = true
        };
        Console.SetOut(standardOutput);
        Console.SetError(standardError);
    }

    public static void SetRoundedWindowRegion(IntPtr hwnd, int width, int height, int cornerEllipseWidth, int cornerEllipseHeight)
    {
        if (hwnd == IntPtr.Zero || width <= 0 || height <= 0)
        {
            return;
        }

        var region = CreateRoundRectRgn(0, 0, width + 1, height + 1, cornerEllipseWidth, cornerEllipseHeight);
        if (region != IntPtr.Zero)
        {
            _ = SetWindowRgn(hwnd, region, true);
        }
    }

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static partial IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static partial IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetWindowRect(IntPtr hWnd, out NativeRect lpRect);

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(IntPtr hwnd);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

    [LibraryImport("user32.dll", SetLastError = true)]
    private static partial uint GetWindowThreadProcessId(IntPtr hWnd, out int processId);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

    [LibraryImport("user32.dll", EntryPoint = "GetMonitorInfoW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetMonitorInfo(IntPtr hMonitor, ref MonitorInfo lpmi);

    [LibraryImport("shcore.dll")]
    private static partial int GetDpiForMonitor(IntPtr hmonitor, MonitorDpiType dpiType, out uint dpiX, out uint dpiY);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AttachConsole(uint processId);

    [LibraryImport("gdi32.dll", SetLastError = true)]
    private static partial IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int widthEllipse, int heightEllipse);

    [LibraryImport("user32.dll", SetLastError = true)]
    private static partial int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, [MarshalAs(UnmanagedType.Bool)] bool redraw);

    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, IntPtr lprcMonitor, IntPtr dwData);

    private enum MonitorDpiType
    {
        Effective = 0
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        public int Size;
        public NativeRect Monitor;
        public NativeRect WorkArea;
        public uint Flags;
    }
}

internal sealed record NativeDisplayMonitor(
    IntPtr Handle,
    NativeRect MonitorBounds,
    NativeRect WorkArea,
    bool IsPrimary,
    uint DpiX,
    uint DpiY);

[StructLayout(LayoutKind.Sequential)]
internal readonly struct NativeRect
{
    public NativeRect(int left, int top, int right, int bottom)
    {
        Left = left;
        Top = top;
        Right = right;
        Bottom = bottom;
    }

    public int Left { get; }
    public int Top { get; }
    public int Right { get; }
    public int Bottom { get; }
    public int Width => Right - Left;
    public int Height => Bottom - Top;

    public NativeRect Inflate(int amount)
    {
        return new NativeRect(Left - amount, Top - amount, Right + amount, Bottom + amount);
    }

    public bool Contains(int x, int y)
    {
        return x >= Left && x <= Right && y >= Top && y <= Bottom;
    }
}
