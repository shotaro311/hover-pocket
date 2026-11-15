using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using HoverPocket.Shell.Display;

namespace HoverPocket.Shell.Providers.Controls;

// One logical monitor (HMONITOR) in the same order as the shell uses: primary first, then left to right.
internal sealed record DdcLogicalMonitor(
    IntPtr Handle,
    string DeviceName,
    bool IsPrimary,
    IReadOnlyList<DdcMonitorDevice> Devices);

// StableKey survives HMONITOR changes (sleep, monitor power cycling). It changes when the monitor
// moves to another connector, which the service treats as a new display.
internal sealed record DdcMonitorDevice(string StableKey, string Model, string? FriendlyName);

internal interface IDdcPlatform
{
    IReadOnlyList<DdcLogicalMonitor> EnumerateMonitors();

    IReadOnlyList<IDdcPhysicalMonitor> OpenPhysicalMonitors(IntPtr monitorHandle);
}

internal interface IDdcPhysicalMonitor : IDisposable
{
    string Description { get; }

    bool TryReadVcpBrightness(out uint current, out uint maximum, out int error);

    bool TryWriteVcpBrightness(uint value, out int error);

    bool TryReadHighLevelBrightness(out uint minimum, out uint current, out uint maximum, out int error);

    bool TryWriteHighLevelBrightness(uint value, out int error);
}

internal sealed class NativeDdcPlatform : IDdcPlatform
{
    private const uint DisplayDeviceActive = 0x00000001;
    private const uint EddGetDeviceInterfaceName = 0x00000001;
    private const byte VcpLuminance = 0x10;
    private readonly DisplayLayoutService _displays = new();
    private readonly object _friendlyNameSync = new();
    private Dictionary<string, string>? _friendlyNames;

    public IReadOnlyList<DdcLogicalMonitor> EnumerateMonitors()
    {
        var monitors = _displays.EnumerateMonitors();
        var result = new List<DdcLogicalMonitor>(monitors.Count);
        foreach (var monitor in monitors)
        {
            if (monitor.NativeHandle == IntPtr.Zero)
            {
                continue;
            }

            result.Add(new DdcLogicalMonitor(
                monitor.NativeHandle,
                monitor.Name,
                monitor.IsPrimary,
                EnumerateMonitorDevices(monitor.Name)));
        }

        return result;
    }

    public IReadOnlyList<IDdcPhysicalMonitor> OpenPhysicalMonitors(IntPtr monitorHandle)
    {
        if (!GetNumberOfPhysicalMonitorsFromHMONITOR(monitorHandle, out var count) || count == 0)
        {
            return [];
        }

        var physical = new PhysicalMonitor[count];
        if (!GetPhysicalMonitorsFromHMONITOR(monitorHandle, count, physical))
        {
            foreach (var item in physical)
            {
                if (item.Handle != IntPtr.Zero)
                {
                    _ = DestroyPhysicalMonitor(item.Handle);
                }
            }

            return [];
        }

        return physical
            .Select(item => (IDdcPhysicalMonitor)new NativePhysicalMonitor(
                new SafePhysicalMonitorHandle(item.Handle),
                item.Description?.Trim() ?? string.Empty))
            .ToArray();
    }

    private IReadOnlyList<DdcMonitorDevice> EnumerateMonitorDevices(string adapterDeviceName)
    {
        var devices = new List<DdcMonitorDevice>();
        for (uint index = 0; index < 16; index++)
        {
            var device = new DisplayDevice { cb = Marshal.SizeOf<DisplayDevice>() };
            if (!EnumDisplayDevices(adapterDeviceName, index, ref device, EddGetDeviceInterfaceName))
            {
                break;
            }

            if ((device.StateFlags & DisplayDeviceActive) == 0)
            {
                continue;
            }

            var parsed = ParseInterfacePath(device.DeviceID);
            if (parsed is null)
            {
                continue;
            }

            devices.Add(new DdcMonitorDevice(parsed.Value.StableKey, parsed.Value.Model, FriendlyName(parsed.Value.Instance)));
        }

        return devices;
    }

    // \\?\DISPLAY#HSJ1600#4&124f0533&0&UID69#{e6f07b5f-...} -> DISPLAY\HSJ1600\4&124f0533&0&UID69
    internal static (string Instance, string Model, string StableKey)? ParseInterfacePath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        var trimmed = path.StartsWith(@"\\?\", StringComparison.Ordinal) ? path[4..] : path;
        var parts = trimmed.Split('#');
        if (parts.Length < 3 || string.IsNullOrWhiteSpace(parts[1]) || string.IsNullOrWhiteSpace(parts[2]))
        {
            return null;
        }

        return ($"{parts[0]}\\{parts[1]}\\{parts[2]}", parts[1], SanitizeKey($"{parts[1]}-{parts[2]}"));
    }

    internal static string SanitizeKey(string value)
    {
        var builder = new StringBuilder(value.Length);
        var previousDash = false;
        foreach (var character in value)
        {
            if (char.IsAsciiLetterOrDigit(character))
            {
                builder.Append(character);
                previousDash = false;
            }
            else if (!previousDash)
            {
                builder.Append('-');
                previousDash = true;
            }
        }

        var key = builder.ToString().Trim('-');
        return key.Length <= 96 ? key : key[..96];
    }

    private string? FriendlyName(string instance)
    {
        lock (_friendlyNameSync)
        {
            if (_friendlyNames is null || !_friendlyNames.ContainsKey(instance))
            {
                _friendlyNames = ReadFriendlyNames();
            }

            return _friendlyNames.TryGetValue(instance, out var name) && name.Length > 0 ? name : null;
        }
    }

    private static Dictionary<string, string> ReadFriendlyNames()
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "root\\WMI",
                "SELECT InstanceName, UserFriendlyName FROM WmiMonitorID WHERE Active = TRUE");
            using var collection = searcher.Get();
            foreach (ManagementObject item in collection)
            {
                using (item)
                {
                    var instance = item["InstanceName"] as string;
                    if (string.IsNullOrWhiteSpace(instance))
                    {
                        continue;
                    }

                    var name = item["UserFriendlyName"] is ushort[] raw
                        ? new string(raw.TakeWhile(code => code != 0).Select(code => (char)code).ToArray()).Trim()
                        : string.Empty;
                    var underscore = instance.LastIndexOf('_');
                    var key = underscore > 0 && instance[(underscore + 1)..].All(char.IsAsciiDigit)
                        ? instance[..underscore]
                        : instance;
                    // Empty names are kept so monitors without an EDID name do not trigger a new query on every read.
                    result[key] = name;
                }
            }
        }
        catch (Exception ex) when (ex is ManagementException or UnauthorizedAccessException or COMException)
        {
        }

        return result;
    }

    private sealed class NativePhysicalMonitor(SafePhysicalMonitorHandle handle, string description) : IDdcPhysicalMonitor
    {
        public string Description { get; } = description;

        public bool TryReadVcpBrightness(out uint current, out uint maximum, out int error)
        {
            var ok = GetVCPFeatureAndVCPFeatureReply(handle, VcpLuminance, out _, out current, out maximum);
            error = ok ? 0 : Marshal.GetLastWin32Error();
            return ok;
        }

        public bool TryWriteVcpBrightness(uint value, out int error)
        {
            var ok = SetVCPFeature(handle, VcpLuminance, value);
            error = ok ? 0 : Marshal.GetLastWin32Error();
            return ok;
        }

        public bool TryReadHighLevelBrightness(out uint minimum, out uint current, out uint maximum, out int error)
        {
            var ok = GetMonitorBrightness(handle, out minimum, out current, out maximum);
            error = ok ? 0 : Marshal.GetLastWin32Error();
            return ok;
        }

        public bool TryWriteHighLevelBrightness(uint value, out int error)
        {
            var ok = SetMonitorBrightness(handle, value);
            error = ok ? 0 : Marshal.GetLastWin32Error();
            return ok;
        }

        public void Dispose() => handle.Dispose();
    }

    private sealed class SafePhysicalMonitorHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public SafePhysicalMonitorHandle(IntPtr handle)
            : base(ownsHandle: true)
        {
            SetHandle(handle);
        }

        protected override bool ReleaseHandle() => DestroyPhysicalMonitor(handle);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PhysicalMonitor
    {
        public IntPtr Handle;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Description;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DisplayDevice
    {
        public int cb;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceString;

        public uint StateFlags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceID;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceKey;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumDisplayDevices(string? device, uint deviceIndex, ref DisplayDevice displayDevice, uint flags);

    [DllImport("dxva2.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor, out uint count);

    [DllImport("dxva2.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetPhysicalMonitorsFromHMONITOR(
        IntPtr monitor,
        uint count,
        [Out] PhysicalMonitor[] physicalMonitorArray);

    [DllImport("dxva2.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyPhysicalMonitor(IntPtr monitor);

    [DllImport("dxva2.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorBrightness(
        SafePhysicalMonitorHandle monitor,
        out uint minimum,
        out uint current,
        out uint maximum);

    [DllImport("dxva2.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetMonitorBrightness(SafePhysicalMonitorHandle monitor, uint brightness);

    [DllImport("dxva2.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVCPFeatureAndVCPFeatureReply(
        SafePhysicalMonitorHandle monitor,
        byte vcpCode,
        out uint codeType,
        out uint currentValue,
        out uint maximumValue);

    [DllImport("dxva2.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetVCPFeature(
        SafePhysicalMonitorHandle monitor,
        byte vcpCode,
        uint newValue);
}
