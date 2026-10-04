using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace HoverPocket.Shell.Capture;

// Only the active recording owns microphones and loopback devices. The clock-paced video
// source requests 20ms blocks, so silent loopback intervals cannot shorten the sound track.
internal sealed class CaptureAudio : IDisposable
{
    private readonly List<(WasapiRecorder Device, BufferedWaveProvider Buffer, ISampleProvider Samples)> _inputs = [];
    private Exception? _failure;
    private long _microphonePackets;
    public long MicrophonePackets => Interlocked.Read(ref _microphonePackets);
    public Exception? Failure => Volatile.Read(ref _failure);
    public int DeviceCount => _inputs.Count;
    public CaptureAudio(bool systemAudio, bool microphone)
    {
        try
        {
            if (systemAudio) Add(new WasapiRecorderBuilder().WithLoopbackCapture().Build(), false);
            if (microphone) Add(new WasapiRecorderBuilder().Build(), true);
        }
        catch { Dispose(); throw; }
    }
    private void Add(WasapiRecorder device, bool microphone)
    {
        try
        {
            device.RecordingStopped += (_, args) => { if (args.Exception is not null) Volatile.Write(ref _failure, args.Exception); };
            device.StartRecording();
            var buffer = new BufferedWaveProvider(device.WaveFormat, TimeSpan.FromMilliseconds(250)) { DiscardOnBufferOverflow = true, ReadFully = false };
            ISampleProvider samples = buffer.ToSampleProvider();
            if (samples.WaveFormat.Channels == 1) samples = new MonoToStereoSampleProvider(samples);
            else if (samples.WaveFormat.Channels != 2) throw new NotSupportedException("音声デバイスをステレオまたはモノラルに設定してください。");
            if (samples.WaveFormat.SampleRate != 48000) samples = new WdlResamplingSampleProvider(samples, 48000);
            device.DataAvailable += (data, _, _, _) => { buffer.AddSamples(data); if (microphone) Interlocked.Increment(ref _microphonePackets); };
            _inputs.Add((device, buffer, samples));
        }
        catch { device.Dispose(); throw; }
    }
    public byte[] ReadPcmBlock()
    {
        var mixed = new float[1920];
        foreach (var input in _inputs)
        {
            var samples = new float[mixed.Length]; var count = input.Samples.Read(samples.AsSpan());
            for (var i = 0; i < count; i++) mixed[i] += samples[i] * (_inputs.Count > 1 ? .7f : 1f);
        }
        return ToPcm16(mixed);
    }
    internal static byte[] ToPcm16(ReadOnlySpan<float> samples)
    {
        var bytes = new byte[samples.Length * 2];
        for (var i = 0; i < samples.Length; i++) System.Buffers.Binary.BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(i * 2, 2), (short)(Math.Clamp(samples[i], -1f, 1f) * short.MaxValue));
        return bytes;
    }
    public void Dispose()
    { foreach (var input in _inputs) { input.Device.StopRecording(); input.Device.Dispose(); } _inputs.Clear(); }
}
