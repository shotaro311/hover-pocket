using System.Text.Json;
using HoverPocket.Shell.Configuration;

namespace HoverPocket.Shell.Providers.CodexVoice;

internal enum CodexVoiceMediaEventKind
{
    MicrophoneAcquired,
    MicrophoneStopped,
    RemoteAudioTrackReceived,
    RemoteAudioTrackStopped,
    RemoteAudioPlaybackSucceeded,
    RemoteAudioPlaybackFailed,
    RemoteAudioPlaybackStopped,
    TransportAttached,
    TransportDetached,
    SafeClose
}

internal sealed class CodexVoiceE2EReceiptStore
{
    private sealed record Receipt(
        int SchemaVersion,
        string Availability,
        bool FeatureEnabled,
        string SessionStatus,
        int SessionCount,
        bool RootThreadPresent,
        bool TransportAttached,
        bool AppServerProcessPresent,
        bool MicrophoneAcquired,
        bool MicrophoneCurrent,
        bool RemoteAudioTrackReceived,
        bool RemoteAudioTrackCurrent,
        bool RemoteAudioTrackEver,
        bool RemoteAudioPlaybackReceived,
        bool RemoteAudioPlaybackCurrent,
        bool RemoteAudioPlaybackEver,
        int UserTranscriptCount,
        int AssistantTranscriptCount,
        int CompleteTranscriptCount,
        string LastTransportEvent);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };

    private readonly object _sync = new();
    private readonly string _receiptPath;
    private CodexVoiceSnapshot _snapshot = DisabledSnapshot();
    private bool _microphoneAcquired;
    private bool _microphoneCurrent;
    private bool _remoteAudioTrackReceived;
    private bool _remoteAudioTrackCurrent;
    private bool _remoteAudioTrackEver;
    private bool _remoteAudioPlaybackReceived;
    private bool _remoteAudioPlaybackCurrent;
    private bool _remoteAudioPlaybackEver;
    private string _lastTransportEvent = "idle";

    private CodexVoiceE2EReceiptStore(string receiptPath)
    {
        _receiptPath = receiptPath;
    }

    public static CodexVoiceE2EReceiptStore? Create(HoverPocketApplicationData applicationData)
    {
        return applicationData.IsIsolatedVoiceE2E
            ? new CodexVoiceE2EReceiptStore(applicationData.VoiceE2EReceiptPath)
            : null;
    }

    internal static CodexVoiceE2EReceiptStore CreateForVerifier(string receiptPath)
    {
        return new CodexVoiceE2EReceiptStore(receiptPath);
    }

    public void RecordSnapshot(CodexVoiceSnapshot snapshot)
    {
        lock (_sync)
        {
            _snapshot = snapshot;
            if (!snapshot.FeatureEnabled && !File.Exists(_receiptPath))
            {
                return;
            }

            WriteLocked();
        }
    }

    public void RecordMediaEvent(CodexVoiceMediaEventKind eventKind)
    {
        lock (_sync)
        {
            if (!_snapshot.FeatureEnabled && !File.Exists(_receiptPath))
            {
                return;
            }

            switch (eventKind)
            {
                case CodexVoiceMediaEventKind.MicrophoneAcquired:
                    _microphoneAcquired = true;
                    _microphoneCurrent = true;
                    _remoteAudioTrackReceived = false;
                    _remoteAudioTrackCurrent = false;
                    _remoteAudioPlaybackReceived = false;
                    _remoteAudioPlaybackCurrent = false;
                    _lastTransportEvent = "microphone_acquired";
                    break;
                case CodexVoiceMediaEventKind.MicrophoneStopped:
                    _microphoneCurrent = false;
                    _lastTransportEvent = "microphone_stopped";
                    break;
                case CodexVoiceMediaEventKind.RemoteAudioTrackReceived:
                    _remoteAudioTrackReceived = true;
                    _remoteAudioTrackCurrent = true;
                    _remoteAudioTrackEver = true;
                    _lastTransportEvent = "remote_audio_track_received";
                    break;
                case CodexVoiceMediaEventKind.RemoteAudioTrackStopped:
                    _remoteAudioTrackCurrent = false;
                    _lastTransportEvent = "remote_audio_track_stopped";
                    break;
                case CodexVoiceMediaEventKind.RemoteAudioPlaybackSucceeded:
                    _remoteAudioPlaybackReceived = true;
                    _remoteAudioPlaybackCurrent = true;
                    _remoteAudioPlaybackEver = true;
                    _lastTransportEvent = "remote_audio_playback_succeeded";
                    break;
                case CodexVoiceMediaEventKind.RemoteAudioPlaybackFailed:
                    _remoteAudioPlaybackReceived = true;
                    _remoteAudioPlaybackCurrent = false;
                    _lastTransportEvent = "remote_audio_playback_failed";
                    break;
                case CodexVoiceMediaEventKind.RemoteAudioPlaybackStopped:
                    _remoteAudioPlaybackCurrent = false;
                    _lastTransportEvent = "remote_audio_playback_stopped";
                    break;
                case CodexVoiceMediaEventKind.TransportAttached:
                    _lastTransportEvent = "transport_attached";
                    break;
                case CodexVoiceMediaEventKind.TransportDetached:
                    ClearCurrentMediaLocked();
                    _lastTransportEvent = "transport_detached";
                    break;
                case CodexVoiceMediaEventKind.SafeClose:
                    ClearCurrentMediaLocked();
                    _lastTransportEvent = "safe_close";
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(eventKind));
            }

            WriteLocked();
        }
    }

    internal static bool TryParseMediaEvent(string? value, out CodexVoiceMediaEventKind eventKind)
    {
        eventKind = value switch
        {
            "microphoneAcquired" => CodexVoiceMediaEventKind.MicrophoneAcquired,
            "microphoneStopped" => CodexVoiceMediaEventKind.MicrophoneStopped,
            "remoteAudioTrackReceived" => CodexVoiceMediaEventKind.RemoteAudioTrackReceived,
            "remoteAudioTrackStopped" => CodexVoiceMediaEventKind.RemoteAudioTrackStopped,
            "remoteAudioPlaybackSucceeded" => CodexVoiceMediaEventKind.RemoteAudioPlaybackSucceeded,
            "remoteAudioPlaybackFailed" => CodexVoiceMediaEventKind.RemoteAudioPlaybackFailed,
            "remoteAudioPlaybackStopped" => CodexVoiceMediaEventKind.RemoteAudioPlaybackStopped,
            "safeClose" => CodexVoiceMediaEventKind.SafeClose,
            _ => default
        };
        return value is "microphoneAcquired"
            or "microphoneStopped"
            or "remoteAudioTrackReceived"
            or "remoteAudioTrackStopped"
            or "remoteAudioPlaybackSucceeded"
            or "remoteAudioPlaybackFailed"
            or "remoteAudioPlaybackStopped"
            or "safeClose";
    }

    private void ClearCurrentMediaLocked()
    {
        _microphoneCurrent = false;
        _remoteAudioTrackCurrent = false;
        _remoteAudioPlaybackCurrent = false;
    }

    private void WriteLocked()
    {
        try
        {
            WriteAtomicallyLocked();
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException
            or JsonException
            or NotSupportedException)
        {
            // Receipt failure must not prevent microphone/app-server cleanup.
        }
    }

    private void WriteAtomicallyLocked()
    {
        var transcript = _snapshot.Transcript;
        var receipt = new Receipt(
            SchemaVersion: 1,
            Availability: WireValue(_snapshot.Availability),
            FeatureEnabled: _snapshot.FeatureEnabled,
            SessionStatus: WireValue(_snapshot.SessionStatus),
            SessionCount: _snapshot.Sessions.Count,
            RootThreadPresent: !string.IsNullOrWhiteSpace(_snapshot.RootThreadId),
            TransportAttached: _snapshot.TransportAttached,
            AppServerProcessPresent: _snapshot.AppServerProcessId.HasValue,
            MicrophoneAcquired: _microphoneAcquired,
            MicrophoneCurrent: _microphoneCurrent,
            RemoteAudioTrackReceived: _remoteAudioTrackReceived,
            RemoteAudioTrackCurrent: _remoteAudioTrackCurrent,
            RemoteAudioTrackEver: _remoteAudioTrackEver,
            RemoteAudioPlaybackReceived: _remoteAudioPlaybackReceived,
            RemoteAudioPlaybackCurrent: _remoteAudioPlaybackCurrent,
            RemoteAudioPlaybackEver: _remoteAudioPlaybackEver,
            UserTranscriptCount: transcript.Count(entry =>
                string.Equals(entry.Role, "user", StringComparison.OrdinalIgnoreCase)),
            AssistantTranscriptCount: transcript.Count(entry =>
                string.Equals(entry.Role, "assistant", StringComparison.OrdinalIgnoreCase)),
            CompleteTranscriptCount: transcript.Count(entry => entry.IsComplete),
            LastTransportEvent: _lastTransportEvent);

        var directory = Path.GetDirectoryName(_receiptPath)
            ?? throw new InvalidOperationException("Voice E2E receipt directory is unavailable.");
        Directory.CreateDirectory(directory);
        var temporaryPath = _receiptPath + ".tmp";
        try
        {
            var data = JsonSerializer.SerializeToUtf8Bytes(receipt, JsonOptions);
            using (var stream = new FileStream(
                temporaryPath,
                FileMode.Create,
                FileAccess.Write,
                FileShare.None,
                bufferSize: 4096,
                FileOptions.WriteThrough))
            {
                stream.Write(data);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, _receiptPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static string WireValue(CodexVoiceAvailability availability)
    {
        return availability switch
        {
            CodexVoiceAvailability.Disabled => "disabled",
            CodexVoiceAvailability.Starting => "starting",
            CodexVoiceAvailability.Ready => "ready",
            CodexVoiceAvailability.SignedOut => "signedOut",
            CodexVoiceAvailability.Unavailable => "unavailable",
            CodexVoiceAvailability.Incompatible => "incompatible",
            CodexVoiceAvailability.Blocked => "blocked",
            _ => "faulted"
        };
    }

    private static string WireValue(CodexVoiceSessionStatus status)
    {
        return status switch
        {
            CodexVoiceSessionStatus.RequestingPermission => "requestingPermission",
            CodexVoiceSessionStatus.Negotiating => "negotiating",
            CodexVoiceSessionStatus.Connecting => "connecting",
            CodexVoiceSessionStatus.Connected => "connected",
            CodexVoiceSessionStatus.Muted => "muted",
            CodexVoiceSessionStatus.Reconnecting => "reconnecting",
            CodexVoiceSessionStatus.Stopping => "stopping",
            CodexVoiceSessionStatus.Closed => "closed",
            CodexVoiceSessionStatus.RecoverableFailure => "recoverableFailure",
            CodexVoiceSessionStatus.BlockedFailure => "blockedFailure",
            _ => "idle"
        };
    }

    private static CodexVoiceSnapshot DisabledSnapshot()
    {
        return new CodexVoiceSnapshot(
            FeatureEnabled: false,
            Availability: CodexVoiceAvailability.Disabled,
            SessionStatus: CodexVoiceSessionStatus.Idle,
            RootThreadId: null,
            TransportAttached: false,
            IsMuted: true,
            Transcript: Array.Empty<CodexVoiceTranscriptEntry>(),
            Sessions: Array.Empty<CodexVoiceThreadSummary>(),
            LastErrorCode: null,
            AppServerProcessId: null,
            RestartAttempt: 0,
            VoiceCount: 0);
    }
}
