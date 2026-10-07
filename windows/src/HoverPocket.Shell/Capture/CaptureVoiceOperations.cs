using System.Windows.Interop;
using HoverPocket.Shell.Providers.Assets;
using Windows.Graphics.Capture;

namespace HoverPocket.Shell.Capture;

internal sealed record CaptureSaveResult(string[] AssetIds, string? Error);
internal sealed record VoiceRecordingState(bool Recording, bool Busy, string? RecordingId, string[] SavedAssetIds, string? Error);

internal sealed partial class CaptureController
{
    internal VoiceCaptureTargets VoiceTargets { get; }
    private string? _recordingId;
    private CaptureWindowExclusion? _voiceCaptureExclusion;
    internal CapturePreferences SavedPreferences => _preferences;
    internal VoiceRecordingState VoiceState => new(Recording, Busy, _recordingId,
        _finishRecording?.IsCompletedSuccessfully == true ? _finishRecording.Result.AssetIds : [],
        _finishRecording?.IsCompletedSuccessfully == true ? _finishRecording.Result.Error : null);

    internal async Task<string> ScreenshotForVoiceAsync(string targetId, string? folderId, string? name, CancellationToken token, System.Windows.Int32Rect? crop = null)
    {
        if (_disposed || Busy || Recording) throw new InvalidOperationException("capture_busy");
        token.ThrowIfCancellationRequested();
        _busy = true; CloseToast(); Report("スクリーンショットを撮影しています…");
        try
        {
            var target = VoiceTargets.Get(targetId);
            using var exclusion = target.Monitor ? new CaptureWindowExclusion() : null;
            var image = await CaptureSnapshot.ReadAsync(VoiceTargets.CaptureItem(targetId), token);
            token.ThrowIfCancellationRequested();
            var id = await SaveScreenshotAsync(image, new(image, false), folderId)
                ?? throw new IOException("screenshot_save_failed");
            if (name is not null) await _store.UpdateAsync([id], "rename", name);
            if (_preferences.ScreenshotToastSeconds > 0) await ShowScreenshotToastAsync(id, _preferences.ScreenshotToastSeconds);
            return id;
        }
        catch { Report("撮影を完了できませんでした。対象と保存先を確認してください。"); throw; }
        finally { _busy = false; Report(_status); }
    }

    internal async Task<string> StartRecordingForVoiceAsync(string targetId, string? folderId, string? name,
        bool systemAudio, bool microphone, CancellationToken token)
    {
        if (_disposed || Busy || Recording) throw new InvalidOperationException("capture_busy");
        token.ThrowIfCancellationRequested();
        _busy = true; CloseToast();
        try
        {
            var target = VoiceTargets.Get(targetId);
            _voiceCaptureExclusion = target.Monitor ? new CaptureWindowExclusion() : null;
            await BeginRecordingAsync(VoiceTargets.CaptureItem(targetId), _preferences with { FolderId = folderId, SystemAudio = systemAudio, Microphone = microphone }, name, token);
            return _recordingId!;
        }
        catch { _voiceCaptureExclusion?.Dispose(); _voiceCaptureExclusion = null; Report("画面収録を開始できませんでした。"); throw; }
        finally { _busy = false; Report(_status); }
    }

    private async Task BeginRecordingAsync(GraphicsCaptureItem item, CapturePreferences options, string? name, CancellationToken token, System.Windows.Int32Rect? crop = null)
    {
        token.ThrowIfCancellationRequested();
        var stage = _files.CreateStage();
        try
        {
            var path = Path.Combine(stage, $"画面収録 {DateTime.Now:yyyy-MM-dd HH-mm-ss}.mp4");
            using (File.Create(path)) { }
            var recorder = await ScreenRecorder.StartAsync(item, path, options.SystemAudio, options.Microphone, crop);
            if (token.IsCancellationRequested)
            {
                recorder.Stop();
                try { await recorder.Completion; } finally { recorder.Dispose(); }
                token.ThrowIfCancellationRequested();
            }
            _recorder = recorder;
            _recordingId = Guid.NewGuid().ToString("N");
            _recordingStage = stage;
            _clock.Start();
            _finishRecording = FinishRecordingAsync(recorder, stage, path, options.FolderId, name, _voiceCaptureExclusion);
            Report("● 収録中。音声で「収録を止めて保存」、またはショートカットで停止できます。");
        }
        catch { await AssetRecycle.MoveAsync(stage); throw; }
    }

    internal async Task<CaptureSaveResult> StopRecordingForVoiceAsync(string recordingId, CancellationToken token)
    {
        if (recordingId != _recordingId || _finishRecording is null) throw new InvalidOperationException("recording_changed");
        token.ThrowIfCancellationRequested();
        var finish = _finishRecording;
        await StopRecordingAsync();
        return await finish;
    }
}

// Keep the conversation and its controls available while capturing a display.
internal sealed class CaptureWindowExclusion : IDisposable
{
    private readonly List<(nint Window, uint Affinity)> _windows = [];
    public CaptureWindowExclusion()
    {
        foreach (System.Windows.Window window in System.Windows.Application.Current.Windows)
        {
            var handle = new WindowInteropHelper(window).Handle;
            if (handle != 0 && GetWindowDisplayAffinity(handle, out var affinity) && SetWindowDisplayAffinity(handle, 0x11)) _windows.Add((handle, affinity));
        }
    }
    public void Dispose() { foreach (var (window, affinity) in _windows) SetWindowDisplayAffinity(window, affinity); _windows.Clear(); }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool GetWindowDisplayAffinity(nint window, out uint affinity);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetWindowDisplayAffinity(nint window, uint affinity);
}
