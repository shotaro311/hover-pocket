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
    internal const string ExpectedPhysicalProviderId = VoiceProviderIds.CodexAppServer;

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
        bool PhysicalMediaUserConfirmed,
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
    private bool _activeAttemptMicrophoneAcquired;
    private bool _remoteAudioTrackReceived;
    private bool _remoteAudioTrackCurrent;
    private bool _remoteAudioTrackEver;
    private bool _remoteAudioPlaybackReceived;
    private bool _remoteAudioPlaybackCurrent;
    private bool _remoteAudioPlaybackEver;
    private bool _hostTransportAttached;
    private bool _physicalMediaUserConfirmed;
    private int _userTranscriptCount;
    private int _assistantTranscriptCount;
    private int _completeTranscriptCount;
    private string _lastTransportEvent = "idle";
    private string? _activeMediaLease;
    private string? _activeMediaProviderId;

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
            var normalizedProviderId = VoiceProviderIds.Normalize(providerId);
            if (!string.Equals(_providerId, normalizedProviderId, StringComparison.Ordinal))
            {
                InvalidateProviderBoundEvidenceLocked();
            }
            _snapshot = snapshot;
            _featureEnabled = featureEnabled;
            _providerId = normalizedProviderId;
            _credentialCurrent = credentialCurrent;
            if (_activeMediaLease is not null
                && string.Equals(_providerId, ExpectedPhysicalProviderId, StringComparison.Ordinal)
                && string.Equals(_activeMediaProviderId, ExpectedPhysicalProviderId, StringComparison.Ordinal))
            {
                _userTranscriptCount = snapshot.Transcript.Count(item =>
                    string.Equals(item.Role, "user", StringComparison.OrdinalIgnoreCase));
                _assistantTranscriptCount = snapshot.Transcript.Count(item =>
                    string.Equals(item.Role, "assistant", StringComparison.OrdinalIgnoreCase));
                _completeTranscriptCount = snapshot.Transcript.Count(item => item.IsFinal);
            }
            else
            {
                _userTranscriptCount = 0;
                _assistantTranscriptCount = 0;
                _completeTranscriptCount = 0;
            }
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
            if (_activeMediaLease is null
                || !string.Equals(_providerId, ExpectedPhysicalProviderId, StringComparison.Ordinal)
                || !string.Equals(_activeMediaProviderId, ExpectedPhysicalProviderId, StringComparison.Ordinal))
            {
                return;
            }
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
            InvalidateProviderBoundEvidenceLocked();
            _lastTransportEvent = "safe_close";
            WriteLocked();
        }
    }

    public string BeginMediaAttempt()
    {
        lock (_sync)
        {
            InvalidateProviderBoundEvidenceLocked();
            _activeMediaLease = Guid.NewGuid().ToString("N");
            _activeMediaProviderId = _providerId;
            _lastTransportEvent = "media_attempt_started";
            WriteLocked();
            return _activeMediaLease;
        }
    }

    public bool PhysicalMediaUserConfirmed
    {
        get
        {
            lock (_sync)
            {
                return _physicalMediaUserConfirmed;
            }
        }
    }

    public bool CanRequestPhysicalMediaConfirmation
    {
        get
        {
            lock (_sync)
            {
                return CanRequestPhysicalMediaConfirmationLocked();
            }
        }
    }

    public bool RecordPhysicalMediaUserConfirmation()
    {
        lock (_sync)
        {
            if (!CanRequestPhysicalMediaConfirmationLocked())
            {
                return false;
            }
            _physicalMediaUserConfirmed = true;
            _lastTransportEvent = "physical_media_user_confirmed";
            WriteLocked();
            return true;
        }
    }

    public bool RecordRendererMediaEvent(
        string? mediaLease,
        VoiceE2EMediaEventKind eventKind)
    {
        lock (_sync)
        {
            if (_activeMediaLease is null
                || !string.Equals(_activeMediaLease, mediaLease, StringComparison.Ordinal)
                || !IsLegalRendererTransitionLocked(eventKind))
            {
                return false;
            }
            ApplyMediaEventLocked(eventKind);
            WriteLocked();
            return true;
        }
    }

    public void RecordMediaEvent(VoiceE2EMediaEventKind eventKind)
    {
        lock (_sync)
        {
            ApplyMediaEventLocked(eventKind);
            if (eventKind is VoiceE2EMediaEventKind.TransportDetached
                or VoiceE2EMediaEventKind.SafeClose)
            {
                _activeMediaLease = null;
                _activeMediaProviderId = null;
                _activeAttemptMicrophoneAcquired = false;
                _hostTransportAttached = false;
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
            _ => default
        };
        return value is "microphoneAcquired"
            or "microphoneStopped"
            or "remoteAudioTrackReceived"
            or "remoteAudioTrackStopped"
            or "remoteAudioPlaybackSucceeded"
            or "remoteAudioPlaybackFailed"
            or "remoteAudioPlaybackStopped";
    }

    private void ClearCurrentMediaLocked()
    {
        _microphoneCurrent = false;
        _remoteAudioTrackCurrent = false;
        _remoteAudioPlaybackCurrent = false;
    }

    private void InvalidateProviderBoundEvidenceLocked()
    {
        _activeMediaLease = null;
        _activeMediaProviderId = null;
        _activeAttemptMicrophoneAcquired = false;
        _hostTransportAttached = false;
        _microphoneAcquired = false;
        _microphoneCurrent = false;
        _remoteAudioTrackReceived = false;
        _remoteAudioTrackCurrent = false;
        _remoteAudioTrackEver = false;
        _remoteAudioPlaybackReceived = false;
        _remoteAudioPlaybackCurrent = false;
        _remoteAudioPlaybackEver = false;
        _userTranscriptCount = 0;
        _assistantTranscriptCount = 0;
        _completeTranscriptCount = 0;
        _timerCapabilityReadbackVerified = false;
        _physicalMediaUserConfirmed = false;
    }

    private bool IsLegalRendererTransitionLocked(VoiceE2EMediaEventKind eventKind)
    {
        return eventKind switch
        {
            VoiceE2EMediaEventKind.MicrophoneAcquired => !_activeAttemptMicrophoneAcquired,
            VoiceE2EMediaEventKind.MicrophoneStopped =>
                _activeAttemptMicrophoneAcquired && _microphoneCurrent,
            VoiceE2EMediaEventKind.RemoteAudioTrackReceived =>
                _activeAttemptMicrophoneAcquired && !_remoteAudioTrackCurrent,
            VoiceE2EMediaEventKind.RemoteAudioTrackStopped => _remoteAudioTrackCurrent,
            VoiceE2EMediaEventKind.RemoteAudioPlaybackSucceeded =>
                _remoteAudioTrackCurrent && !_remoteAudioPlaybackCurrent,
            VoiceE2EMediaEventKind.RemoteAudioPlaybackFailed =>
                _remoteAudioTrackCurrent && !_remoteAudioPlaybackCurrent,
            VoiceE2EMediaEventKind.RemoteAudioPlaybackStopped => _remoteAudioPlaybackCurrent,
            _ => false
        };
    }

    private bool CanRequestPhysicalMediaConfirmationLocked()
    {
        return !_physicalMediaUserConfirmed
            && string.Equals(_providerId, ExpectedPhysicalProviderId, StringComparison.Ordinal)
            && string.Equals(_activeMediaProviderId, ExpectedPhysicalProviderId, StringComparison.Ordinal)
            && _activeMediaLease is not null
            && _hostTransportAttached
            && _activeAttemptMicrophoneAcquired
            && _microphoneCurrent
            && _remoteAudioTrackCurrent
            && _remoteAudioPlaybackCurrent;
    }

    private void ApplyMediaEventLocked(VoiceE2EMediaEventKind eventKind)
    {
        switch (eventKind)
        {
            case VoiceE2EMediaEventKind.MicrophoneAcquired:
                _microphoneAcquired = true;
                _microphoneCurrent = true;
                _activeAttemptMicrophoneAcquired = true;
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
                _hostTransportAttached = true;
                _lastTransportEvent = "transport_attached";
                break;
            case VoiceE2EMediaEventKind.TransportDetached:
                _hostTransportAttached = false;
                ClearCurrentMediaLocked();
                _lastTransportEvent = "transport_detached";
                break;
            case VoiceE2EMediaEventKind.SafeClose:
                _hostTransportAttached = false;
                ClearCurrentMediaLocked();
                _lastTransportEvent = "safe_close";
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(eventKind));
        }
    }

    private void WriteLocked()
    {
        try
        {
            var receipt = new Receipt(
                SchemaVersion: 2,
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
                UserTranscriptCount: _userTranscriptCount,
                AssistantTranscriptCount: _assistantTranscriptCount,
                CompleteTranscriptCount: _completeTranscriptCount,
                TimerCapabilityReadbackVerified: _timerCapabilityReadbackVerified,
                PhysicalMediaUserConfirmed: _physicalMediaUserConfirmed,
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
