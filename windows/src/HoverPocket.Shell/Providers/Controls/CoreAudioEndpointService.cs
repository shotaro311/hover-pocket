using System.Runtime.InteropServices;

namespace HoverPocket.Shell.Providers.Controls;

internal sealed class CoreAudioEndpointService : IVolumeEndpointService, IDisposable
{
    private static readonly Guid AudioEndpointVolumeId = new("5CDF2C82-841E-4546-9722-0CF74078229A");
    private static readonly Guid EventContext = new("8E7C4219-14B0-490F-BCA2-603A9A54A4AE");
    private static readonly TimeSpan FallbackInterval = TimeSpan.FromSeconds(2);

    private readonly object _monitorSync = new();
    private IMMDeviceEnumerator? _monitorEnumerator;
    private IMMDevice? _monitorDevice;
    private IAudioEndpointVolume? _monitorEndpoint;
    private EndpointVolumeCallback? _monitorCallback;
    private string? _monitorEndpointId;
    private CancellationTokenSource? _monitorCancellation;
    private Task? _fallbackTask;
    private bool _disposed;

    public event EventHandler<VolumeState>? StateChanged;

    public async Task StartMonitoringAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        CancellationTokenSource monitorCancellation;
        lock (_monitorSync)
        {
            if (_monitorCancellation is not null)
            {
                return;
            }

            monitorCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            _monitorCancellation = monitorCancellation;
        }

        await Task.Run(EnsureMonitorEndpoint, cancellationToken);
        lock (_monitorSync)
        {
            if (_monitorCancellation == monitorCancellation)
            {
                _fallbackTask = RunFallbackLoopAsync(monitorCancellation.Token);
            }
        }
    }

    public void StopMonitoring()
    {
        CancellationTokenSource? cancellation;
        lock (_monitorSync)
        {
            cancellation = _monitorCancellation;
            _monitorCancellation = null;
            _fallbackTask = null;
            ReleaseMonitorEndpointLocked();
        }

        cancellation?.Cancel();
        cancellation?.Dispose();
    }

    public Task<VolumeState> ReadAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return Task.Run(() => WithEndpoint(Read), cancellationToken);
    }

    public Task<VolumeState> SetVolumeAsync(int value, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return Task.Run(() => WithEndpoint(endpoint =>
        {
            var expected = Math.Clamp(value, 0, 100);
            ThrowIfFailed(endpoint.SetMasterVolumeLevelScalar(expected / 100f, EventContext));
            var readback = Read(endpoint);
            return Math.Abs(readback.Value - expected) <= 1
                ? readback
                : readback with { Error = $"Volume readback did not match {expected}%." };
        }), cancellationToken);
    }

    public Task<VolumeState> ToggleMuteAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return Task.Run(() => WithEndpoint(endpoint =>
        {
            ThrowIfFailed(endpoint.GetMute(out var muted));
            var expected = !muted;
            ThrowIfFailed(endpoint.SetMute(expected, EventContext));
            var readback = Read(endpoint);
            return readback.Muted == expected
                ? readback
                : readback with { Error = "Mute readback did not match the requested state." };
        }), cancellationToken);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        StopMonitoring();
    }

    private async Task RunFallbackLoopAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(FallbackInterval);
        try
        {
            while (await timer.WaitForNextTickAsync(cancellationToken))
            {
                await Task.Run(EnsureMonitorEndpoint, cancellationToken);
                var state = await ReadAsync(cancellationToken);
                Publish(state);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private void EnsureMonitorEndpoint()
    {
        IMMDeviceEnumerator? enumerator = null;
        IMMDevice? device = null;
        object? activated = null;
        try
        {
            enumerator = (IMMDeviceEnumerator)(object)new MMDeviceEnumeratorComObject();
            ThrowIfFailed(enumerator.GetDefaultAudioEndpoint(AudioDataFlow.Render, AudioRole.Multimedia, out device));
            ThrowIfFailed(device.GetId(out var endpointId));

            lock (_monitorSync)
            {
                if (_monitorCancellation is null || string.Equals(_monitorEndpointId, endpointId, StringComparison.Ordinal))
                {
                    return;
                }
            }

            var endpointVolumeId = AudioEndpointVolumeId;
            ThrowIfFailed(device.Activate(ref endpointVolumeId, ClassContext.All, IntPtr.Zero, out activated));
            if (activated is not IAudioEndpointVolume endpoint)
            {
                return;
            }

            var callback = new EndpointVolumeCallback(OnEndpointVolumeChanged);
            ThrowIfFailed(endpoint.RegisterControlChangeNotify(callback));

            lock (_monitorSync)
            {
                if (_monitorCancellation is null)
                {
                    _ = endpoint.UnregisterControlChangeNotify(callback);
                    return;
                }

                ReleaseMonitorEndpointLocked();
                _monitorEnumerator = enumerator;
                _monitorDevice = device;
                _monitorEndpoint = endpoint;
                _monitorCallback = callback;
                _monitorEndpointId = endpointId;
                enumerator = null;
                device = null;
                activated = null;
            }
        }
        catch (Exception ex) when (ex is COMException or InvalidCastException)
        {
            Publish(new VolumeState(false, 0, false, "Volume control is unavailable."));
        }
        finally
        {
            ReleaseComObject(activated);
            ReleaseComObject(device);
            ReleaseComObject(enumerator);
        }
    }

    private void ReleaseMonitorEndpointLocked()
    {
        if (_monitorEndpoint is not null && _monitorCallback is not null)
        {
            try
            {
                _ = _monitorEndpoint.UnregisterControlChangeNotify(_monitorCallback);
            }
            catch (COMException)
            {
            }
        }

        ReleaseComObject(_monitorEndpoint);
        ReleaseComObject(_monitorDevice);
        ReleaseComObject(_monitorEnumerator);
        _monitorEndpoint = null;
        _monitorDevice = null;
        _monitorEnumerator = null;
        _monitorCallback = null;
        _monitorEndpointId = null;
    }

    private void OnEndpointVolumeChanged(VolumeState state)
    {
        ThreadPool.QueueUserWorkItem(static payload =>
        {
            var (owner, snapshot) = ((CoreAudioEndpointService, VolumeState))payload!;
            owner.Publish(snapshot);
        }, (this, state));
    }

    private void Publish(VolumeState state)
    {
        if (!_disposed)
        {
            StateChanged?.Invoke(this, state);
        }
    }

    private static VolumeState WithEndpoint(Func<IAudioEndpointVolume, VolumeState> action)
    {
        IMMDeviceEnumerator? enumerator = null;
        IMMDevice? device = null;
        object? activated = null;
        try
        {
            enumerator = (IMMDeviceEnumerator)(object)new MMDeviceEnumeratorComObject();
            ThrowIfFailed(enumerator.GetDefaultAudioEndpoint(AudioDataFlow.Render, AudioRole.Multimedia, out device));
            var endpointVolumeId = AudioEndpointVolumeId;
            ThrowIfFailed(device.Activate(ref endpointVolumeId, ClassContext.All, IntPtr.Zero, out activated));
            return activated is IAudioEndpointVolume endpoint
                ? action(endpoint)
                : new VolumeState(false, 0, false, "Volume control is unavailable.");
        }
        catch (Exception ex) when (ex is COMException or InvalidCastException)
        {
            return new VolumeState(false, 0, false, "Volume control is unavailable.");
        }
        finally
        {
            ReleaseComObject(activated);
            ReleaseComObject(device);
            ReleaseComObject(enumerator);
        }
    }

    private static VolumeState Read(IAudioEndpointVolume endpoint)
    {
        ThrowIfFailed(endpoint.GetMasterVolumeLevelScalar(out var volume));
        ThrowIfFailed(endpoint.GetMute(out var muted));
        return new VolumeState(true, (int)Math.Round(Math.Clamp(volume, 0, 1) * 100), muted);
    }

    private static void ThrowIfFailed(int result)
    {
        if (result < 0)
        {
            Marshal.ThrowExceptionForHR(result);
        }
    }

    private static void ReleaseComObject(object? value)
    {
        if (value is not null && Marshal.IsComObject(value))
        {
            _ = Marshal.FinalReleaseComObject(value);
        }
    }

    private enum AudioDataFlow
    {
        Render,
        Capture,
        All
    }

    private enum AudioRole
    {
        Console,
        Multimedia,
        Communications
    }

    [Flags]
    private enum ClassContext : uint
    {
        InProcServer = 0x1,
        InProcHandler = 0x2,
        LocalServer = 0x4,
        RemoteServer = 0x10,
        All = InProcServer | InProcHandler | LocalServer | RemoteServer
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct AudioVolumeNotificationData
    {
        public Guid EventContext;

        [MarshalAs(UnmanagedType.Bool)]
        public bool Muted;

        public float MasterVolume;
        public uint Channels;
    }

    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    private sealed class EndpointVolumeCallback : IAudioEndpointVolumeCallback
    {
        private readonly Action<VolumeState> _onChanged;

        public EndpointVolumeCallback(Action<VolumeState> onChanged)
        {
            _onChanged = onChanged;
        }

        public int OnNotify(IntPtr notificationData)
        {
            if (notificationData == IntPtr.Zero)
            {
                return 0;
            }

            var data = Marshal.PtrToStructure<AudioVolumeNotificationData>(notificationData);
            _onChanged(new VolumeState(
                true,
                (int)Math.Round(Math.Clamp(data.MasterVolume, 0, 1) * 100),
                data.Muted));
            return 0;
        }
    }

    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private sealed class MMDeviceEnumeratorComObject
    {
    }

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig]
        int EnumAudioEndpoints(AudioDataFlow dataFlow, uint stateMask, out IntPtr devices);

        [PreserveSig]
        int GetDefaultAudioEndpoint(AudioDataFlow dataFlow, AudioRole role, out IMMDevice endpoint);

        [PreserveSig]
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);

        [PreserveSig]
        int RegisterEndpointNotificationCallback(IntPtr callback);

        [PreserveSig]
        int UnregisterEndpointNotificationCallback(IntPtr callback);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig]
        int Activate(
            ref Guid interfaceId,
            ClassContext classContext,
            IntPtr activationParameters,
            [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);

        [PreserveSig]
        int OpenPropertyStore(uint accessMode, out IntPtr properties);

        [PreserveSig]
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);

        [PreserveSig]
        int GetState(out uint state);
    }

    [ComImport]
    [Guid("657804FA-D6AD-4496-8A60-352752AF4F89")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolumeCallback
    {
        [PreserveSig]
        int OnNotify(IntPtr notificationData);
    }

    [ComImport]
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume
    {
        [PreserveSig]
        int RegisterControlChangeNotify(IAudioEndpointVolumeCallback notify);

        [PreserveSig]
        int UnregisterControlChangeNotify(IAudioEndpointVolumeCallback notify);

        [PreserveSig]
        int GetChannelCount(out uint channelCount);

        [PreserveSig]
        int SetMasterVolumeLevel(float level, Guid eventContext);

        [PreserveSig]
        int SetMasterVolumeLevelScalar(float level, Guid eventContext);

        [PreserveSig]
        int GetMasterVolumeLevel(out float level);

        [PreserveSig]
        int GetMasterVolumeLevelScalar(out float level);

        [PreserveSig]
        int SetChannelVolumeLevel(uint channelNumber, float level, Guid eventContext);

        [PreserveSig]
        int SetChannelVolumeLevelScalar(uint channelNumber, float level, Guid eventContext);

        [PreserveSig]
        int GetChannelVolumeLevel(uint channelNumber, out float level);

        [PreserveSig]
        int GetChannelVolumeLevelScalar(uint channelNumber, out float level);

        [PreserveSig]
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool muted, Guid eventContext);

        [PreserveSig]
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool muted);

        [PreserveSig]
        int GetVolumeStepInfo(out uint step, out uint stepCount);

        [PreserveSig]
        int VolumeStepUp(Guid eventContext);

        [PreserveSig]
        int VolumeStepDown(Guid eventContext);

        [PreserveSig]
        int QueryHardwareSupport(out uint hardwareSupportMask);

        [PreserveSig]
        int GetVolumeRange(out float minimum, out float maximum, out float increment);
    }
}
