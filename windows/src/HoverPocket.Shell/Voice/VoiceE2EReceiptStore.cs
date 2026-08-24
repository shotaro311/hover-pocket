using System.Text.Json;

namespace HoverPocket.Shell.Voice;

internal enum VoiceE2EMediaEventKind
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

internal sealed class VoiceE2EReceiptStore
{
    private sealed record Receipt(
        int SchemaVersion,
        string ProviderId,
        string Availability,
        bool FeatureEnabled,
        string SessionStatus,
        bool RootSessionPresent,
        bool TransportAttached,
        bool RealtimeAttached,
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
        bool TimerCapabilityReadbackVerified,
        bool CredentialCurrent,
        string LastTransportEvent);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };

    private readonly object _sync = new();
    private readonly string _receiptPath;
    private CodexVoiceSnapshot _snapshot = CodexVoiceSnapshot.Disabled;
    private string _providerId = VoiceProviderIds.Off;
    private bool _featureEnabled;
    private bool _credentialCurrent;
    private bool _timerCapabilityReadbackVerified;
    private bool _microphoneAcquired;
    private bool _microphoneCurrent;
    private bool _remoteAudioTrackReceived;
    private bool _remoteAudioTrackCurrent;
    private bool _remoteAudioTrackEver;
    private bool _remoteAudioPlaybackReceived;
    private bool _remoteAudioPlaybackCurrent;
    private bool _remoteAudioPlaybackEver;
    private string _lastTransportEvent = "idle";

    public VoiceE2EReceiptStore(string receiptPath)
    {
        _receiptPath = receiptPath;
    }

    public void RecordSnapshot(
        CodexVoiceSnapshot snapshot,
        bool featureEnabled,
        string providerId,
        bool credentialCurrent)
    {
        lock (_sync)
        {
            _snapshot = snapshot;
            _featureEnabled = featureEnabled;
            _providerId = VoiceProviderIds.Normalize(providerId);
            _credentialCurrent = credentialCurrent;
            WriteLocked();
        }
    }

    public void RecordCredentialState(bool credentialCurrent)
    {
        lock (_sync)
        {
            _credentialCurrent = credentialCurrent;
            WriteLocked();
        }
    }

    public void RecordTimerCapabilityReadback()
    {
        lock (_sync)
        {
            _timerCapabilityReadbackVerified = true;
            WriteLocked();
        }
    }

    public void RecordShutdown(bool credentialCurrent)
    {
        lock (_sync)
        {
            _snapshot = CodexVoiceSnapshot.Disabled;
            _featureEnabled = false;
            _credentialCurrent = credentialCurrent;
            ClearCurrentMediaLocked();
            _lastTransportEvent = "safe_close";
            WriteLocked();
        }
    }

    public void RecordMediaEvent(VoiceE2EMediaEventKind eventKind)
    {
        lock (_sync)
        {
            switch (eventKind)
            {
                case VoiceE2EMediaEventKind.MicrophoneAcquired:
                    _microphoneAcquired = true;
                    _microphoneCurrent = true;
                    _lastTransportEvent = "microphone_acquired";
                    break;
                case VoiceE2EMediaEventKind.MicrophoneStopped:
                    _microphoneCurrent = false;
                    _lastTransportEvent = "microphone_stopped";
                    break;
                case VoiceE2EMediaEventKind.RemoteAudioTrackReceived:
                    _remoteAudioTrackReceived = true;
                    _remoteAudioTrackCurrent = true;
                    _remoteAudioTrackEver = true;
                    _lastTransportEvent = "remote_audio_track_received";
                    break;
                case VoiceE2EMediaEventKind.RemoteAudioTrackStopped:
                    _remoteAudioTrackCurrent = false;
                    _lastTransportEvent = "remote_audio_track_stopped";
                    break;
                case VoiceE2EMediaEventKind.RemoteAudioPlaybackSucceeded:
                    _remoteAudioPlaybackReceived = true;
                    _remoteAudioPlaybackCurrent = true;
                    _remoteAudioPlaybackEver = true;
                    _lastTransportEvent = "remote_audio_playback_succeeded";
                    break;
                case VoiceE2EMediaEventKind.RemoteAudioPlaybackFailed:
                    _remoteAudioPlaybackReceived = true;
                    _remoteAudioPlaybackCurrent = false;
                    _lastTransportEvent = "remote_audio_playback_failed";
                    break;
                case VoiceE2EMediaEventKind.RemoteAudioPlaybackStopped:
                    _remoteAudioPlaybackCurrent = false;
                    _lastTransportEvent = "remote_audio_playback_stopped";
                    break;
                case VoiceE2EMediaEventKind.TransportAttached:
                    _lastTransportEvent = "transport_attached";
                    break;
                case VoiceE2EMediaEventKind.TransportDetached:
                    ClearCurrentMediaLocked();
                    _lastTransportEvent = "transport_detached";
                    break;
                case VoiceE2EMediaEventKind.SafeClose:
                    ClearCurrentMediaLocked();
                    _lastTransportEvent = "safe_close";
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(eventKind));
            }
            WriteLocked();
        }
    }

    internal static bool TryParseMediaEvent(
        string? value,
        out VoiceE2EMediaEventKind eventKind)
    {
        eventKind = value switch
        {
            "microphoneAcquired" => VoiceE2EMediaEventKind.MicrophoneAcquired,
            "microphoneStopped" => VoiceE2EMediaEventKind.MicrophoneStopped,
            "remoteAudioTrackReceived" => VoiceE2EMediaEventKind.RemoteAudioTrackReceived,
            "remoteAudioTrackStopped" => VoiceE2EMediaEventKind.RemoteAudioTrackStopped,
            "remoteAudioPlaybackSucceeded" => VoiceE2EMediaEventKind.RemoteAudioPlaybackSucceeded,
            "remoteAudioPlaybackFailed" => VoiceE2EMediaEventKind.RemoteAudioPlaybackFailed,
            "remoteAudioPlaybackStopped" => VoiceE2EMediaEventKind.RemoteAudioPlaybackStopped,
            "transportAttached" => VoiceE2EMediaEventKind.TransportAttached,
            "transportDetached" => VoiceE2EMediaEventKind.TransportDetached,
            "safeClose" => VoiceE2EMediaEventKind.SafeClose,
            _ => default
        };
        return value is "microphoneAcquired"
            or "microphoneStopped"
            or "remoteAudioTrackReceived"
            or "remoteAudioTrackStopped"
            or "remoteAudioPlaybackSucceeded"
            or "remoteAudioPlaybackFailed"
            or "remoteAudioPlaybackStopped"
            or "transportAttached"
            or "transportDetached"
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
            var transcript = _snapshot.Transcript;
            var receipt = new Receipt(
                SchemaVersion: 1,
                ProviderId: _providerId,
                Availability: WireValue(_snapshot.Availability),
                FeatureEnabled: _featureEnabled,
                SessionStatus: WireValue(_snapshot.SessionStatus),
                RootSessionPresent: !string.IsNullOrWhiteSpace(_snapshot.RootSessionId),
                TransportAttached: _snapshot.TransportAttached,
                RealtimeAttached: _snapshot.RealtimeAttached,
                MicrophoneAcquired: _microphoneAcquired,
                MicrophoneCurrent: _microphoneCurrent,
                RemoteAudioTrackReceived: _remoteAudioTrackReceived,
                RemoteAudioTrackCurrent: _remoteAudioTrackCurrent,
                RemoteAudioTrackEver: _remoteAudioTrackEver,
                RemoteAudioPlaybackReceived: _remoteAudioPlaybackReceived,
                RemoteAudioPlaybackCurrent: _remoteAudioPlaybackCurrent,
                RemoteAudioPlaybackEver: _remoteAudioPlaybackEver,
                UserTranscriptCount: transcript.Count(item =>
                    string.Equals(item.Role, "user", StringComparison.OrdinalIgnoreCase)),
                AssistantTranscriptCount: transcript.Count(item =>
                    string.Equals(item.Role, "assistant", StringComparison.OrdinalIgnoreCase)),
                CompleteTranscriptCount: transcript.Count(item => item.IsFinal),
                TimerCapabilityReadbackVerified: _timerCapabilityReadbackVerified,
                CredentialCurrent: _credentialCurrent,
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
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException
            or JsonException
            or NotSupportedException)
        {
            // Receipt failure must never prevent media or credential cleanup.
        }
    }

    private static string WireValue(CodexVoiceAvailability availability) => availability switch
    {
        CodexVoiceAvailability.Disabled => "disabled",
        CodexVoiceAvailability.Ready => "ready",
        CodexVoiceAvailability.Unavailable => "unavailable",
        CodexVoiceAvailability.SignedOut => "signed_out",
        CodexVoiceAvailability.SchemaMismatch => "schema_mismatch",
        CodexVoiceAvailability.CapabilityBlocked => "capability_blocked",
        _ => "unavailable"
    };

    private static string WireValue(CodexVoiceSessionStatus status) => status switch
    {
        CodexVoiceSessionStatus.RequestingPermission => "requesting_permission",
        CodexVoiceSessionStatus.Negotiating => "negotiating",
        CodexVoiceSessionStatus.Connecting => "connecting",
        CodexVoiceSessionStatus.Stopping => "stopping",
        CodexVoiceSessionStatus.Recovering => "recovering",
        CodexVoiceSessionStatus.RecoverableFailure => "recoverable_failure",
        CodexVoiceSessionStatus.BlockedFailure => "blocked_failure",
        _ => "idle"
    };
}
