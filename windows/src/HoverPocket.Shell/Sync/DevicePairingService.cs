using System.Diagnostics;
using System.Text.Json;
using HoverPocket.Assets;

namespace HoverPocket.Shell.Sync;

internal sealed record PairingState(string Phase = "idle", string? Code = null, string? ApprovalId = null,
    string? PeerName = null, string? Platform = null, string? Verification = null, DateTimeOffset? ExpiresAt = null, string? Error = null);

internal sealed class DevicePairingService(AssetStore store, Func<SyncthingLibraryLink>? apiFactory = null, string? helperPath = null, string? deviceName = null) : IDisposable
{
    private readonly SemaphoreSlim _actions = new(1, 1);
    private Process? _process;
    private CancellationTokenSource? _session;
    private Task? _running;
    private PairingState _state = new();
    private string? _role;
    private DateTimeOffset _lastStart;
    internal PairingState State => Volatile.Read(ref _state);
    private void Set(PairingState value) => Volatile.Write(ref _state, value);
    internal async Task<object> Status(CancellationToken token)
    {
        try
        {
            using var api = OpenApi();
            var plan = await api.Plan(await store.GetSyncStatusAsync(token), token);
            return new { available = File.Exists(HelperPath), devices = await api.Devices(plan, token), session = State, role = _role, error = File.Exists(HelperPath) ? null : "helper_missing" };
        }
        catch { return new { available = false, devices = Array.Empty<LinkedDevice>(), session = State, role = _role, error = "syncthing_unavailable" }; }
    }
    private string HelperPath => helperPath ?? Path.Combine(AppContext.BaseDirectory, "hoverpocket-pairing.exe");
    private SyncthingLibraryLink OpenApi() => apiFactory?.Invoke() ?? SyncthingLibraryLink.Open();
    internal async Task<PairingState> Start(string role, string? code, CancellationToken token)
    {
        await _actions.WaitAsync(token);
        try
        {
            if (State.Phase is "starting" or "waiting" or "peer" or "applying") throw new IOException("接続が進行中です。取り消してから再試行してください。");
            if (DateTimeOffset.UtcNow - _lastStart < TimeSpan.FromSeconds(3)) throw new IOException("少し待ってから再試行してください。");
            if (!File.Exists(HelperPath)) throw new IOException("端末連携のプログラムがありません。");
            await StopSession();
            using var api = OpenApi();
            var plan = await api.Plan(await store.GetSyncStatusAsync(token), token);
            if (role == "invite" && plan.GroupId is null)
            {
                var group = Guid.NewGuid().ToString("D");
                plan = plan with { GroupId = group, FolderId = "hoverpocket-library-" + group, Path = ManagedPath(group) };
            }
            _role = role; _lastStart = DateTimeOffset.UtcNow;
            Set(new("starting", ExpiresAt: _lastStart.AddMinutes(5)));
            _session = new CancellationTokenSource(TimeSpan.FromMinutes(5));
            _running = Task.Run(() => Run(plan, role, code, _session.Token));
            return State;
        }
        finally { _actions.Release(); }
    }
    private string ManagedPath(string group) => Path.Combine(Path.GetDirectoryName(store.Root)!, "SyncTransport", group);
    internal async Task<PairingState> Approve(string approvalId, CancellationToken token)
    {
        await _actions.WaitAsync(token);
        try
        {
            var state = State;
            if (_role != "invite" || state.Phase != "peer" || state.ApprovalId != approvalId || state.ExpiresAt <= DateTimeOffset.UtcNow)
                throw new IOException("この確認は期限切れです。接続をやり直してください。");
            Set(state with { Phase = "applying", Code = null });
            await Send(new { action = "approve", approvalId });
            return State;
        }
        finally { _actions.Release(); }
    }
    private async Task Send(object value)
    {
        var process = _process ?? throw new IOException("接続が終了しました。");
        await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(value));
        await process.StandardInput.FlushAsync();
    }
    private async Task Run(LinkPlan plan, string role, string? code, CancellationToken token)
    {
        string? peerId = null; bool rollback = false, completed = false, enabledForPairing = false; PairingState? failure = null;
        AssetSyncStatus? before = null;
        try
        {
            before = await store.GetSyncStatusAsync(token);
            var info = new ProcessStartInfo(HelperPath) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
            info.Environment.Remove("HOVERPOCKET_PAIRING_TEST_RELAY");
            var process = Process.Start(info) ?? throw new IOException("連携を開始できません。"); _process = process;
            _ = process.StandardError.ReadToEndAsync(); // Never forward raw helper diagnostics or secrets.
            using var kill = token.Register(() => { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { } });
            await Send(new { role, code, deviceId = plan.DeviceId, deviceName = deviceName ?? Environment.MachineName, platform = "windows", groupId = plan.GroupId, folderId = plan.FolderId });
            while (await process.StandardOutput.ReadLineAsync(token) is { } line)
            {
                if (line.Length > 16384) throw new IOException("接続応答が不正です。");
                using var doc = JsonDocument.Parse(line); var e = doc.RootElement;
                switch (e.GetProperty("event").GetString())
                {
                    case "code": Set(State with { Phase = "waiting", Code = e.GetProperty("code").GetString() }); break;
                    case "peer":
                        var peer = e.GetProperty("peer");
                        Set(State with { Phase = "peer", ApprovalId = e.GetProperty("approvalId").GetString(), PeerName = peer.GetProperty("deviceName").GetString(), Platform = peer.GetProperty("platform").GetString(), Verification = e.GetProperty("verification").GetString(), Code = null });
                        if (role == "join") await Send(new { action = "ready", approvalId = State.ApprovalId });
                        break;
                    case "approved":
                        token.ThrowIfCancellationRequested();
                        if (State.ApprovalId != e.GetProperty("approvalId").GetString()) throw new IOException("接続確認が一致しません。");
                        var group = e.GetProperty("groupId").GetString()!; var folder = e.GetProperty("folderId").GetString()!;
                        if (!AssetSyncFormat.IsId(group) || folder.Length > 80 || !folder.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_')) throw new IOException("同期グループが不正です。");
                        if (plan.GroupId is not null && (plan.GroupId != group || plan.FolderId != folder)) throw new IOException("別のライブラリには接続できません。");
                        plan = plan with { GroupId = group, FolderId = folder, Path = plan.Path ?? ManagedPath(group) };
                        peerId = e.GetProperty("peer").GetProperty("deviceId").GetString()!;
                        Set(State with { Phase = "applying", Code = null });
                        using (var api = OpenApi())
                        {
                            var existing = before.Configured ? await api.Devices(plan, token) : [];
                            rollback = !existing.Any(d => d.Id == peerId);
                            SyncthingLibraryLink.PrepareMarker(plan);
                            await api.Add(plan, peerId, State.PeerName!, token);
                        }
                        await store.ConfigureSyncAsync(plan.Path, false, token);
                        enabledForPairing = before.Enabled != true;
                        await store.SetSyncEnabledAsync(true, token);
                        await Send(new { action = "applied", approvalId = State.ApprovalId });
                        break;
                    case "complete":
                        completed = true; Set(new("complete", PeerName: State.PeerName, Platform: State.Platform)); return;
                    case "error":
                        throw new IOException(e.GetProperty("reason").GetString() switch {
                            "expired" => "コードの有効期限が切れました。新しいコードで接続してください。",
                            "different_library" => "別のライブラリに参加済みです。接続先を確認してください。",
                            "peer_declined" or "cancelled" => "相手の端末で接続が取り消されました。",
                            "peer_setup_failed" => "相手の端末で設定を完了できませんでした。",
                            _ => "接続できませんでした。コードとネット接続を確認し、新しいコードで再試行してください。" });
                }
            }
            throw new IOException("接続が中断されました。再試行してください。");
        }
        catch (OperationCanceledException) { failure = State.ExpiresAt <= DateTimeOffset.UtcNow ? new("error", Error: "コードの有効期限が切れました。") : new("idle"); }
        catch (Exception ex)
        {
            if (State.Phase == "applying" && State.ApprovalId is { } approvalId)
            {
                try { await Send(new { action = "failed", approvalId }); await Task.Delay(200); } catch { }
            }
            failure = new("error", Error: ex is IOException ? ex.Message : "接続を完了できませんでした。再試行してください。");
        }
        finally
        {
            if (!completed && (rollback || enabledForPairing))
            {
                var cleanupFailed = false;
                // Restore pause independently of membership cleanup: either may fail.
                if (enabledForPairing)
                {
                    try { await store.SetSyncEnabledAsync(false); }
                    catch { cleanupFailed = true; }
                }
                if (rollback && peerId is not null)
                {
                    try
                    {
                        using var api = OpenApi();
                        await api.Remove(plan, peerId, CancellationToken.None);
                    }
                    catch { cleanupFailed = true; }
                }
                if (cleanupFailed) failure = new("error", Error: "接続の復旧を確認できません。同期を一時停止し、接続端末を確認してください。");
            }
            var process = _process; _process = null;
            try { if (process is not null && !process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            process?.Dispose();
            if (failure is not null) Set(failure);
        }
    }
    private async Task StopSession()
    {
        _session?.Cancel();
        if (_running is not null) { try { await _running; } catch { } }
        _session?.Dispose(); _session = null; _running = null;
    }
    internal async Task<PairingState> Cancel(CancellationToken token)
    {
        await _actions.WaitAsync(token);
        try { await StopSession(); if (State.Phase != "error") Set(new()); return State; }
        finally { _actions.Release(); }
    }
    internal async Task Remove(string id, CancellationToken token)
    {
        await _actions.WaitAsync(token);
        try
        {
            if (State.Phase is "starting" or "waiting" or "peer" or "applying") throw new IOException("接続中は端末を解除できません。");
            using var api = OpenApi();
            await api.Remove(await api.Plan(await store.GetSyncStatusAsync(token), token), id, token);
        }
        finally { _actions.Release(); }
    }
    public void Dispose() { _session?.Cancel(); }
}
