using System.Text.Json;
using HoverPocket.Assets;
using HoverPocket.Shell.Configuration;

namespace HoverPocket.Shell.Bridge;

internal sealed partial class PanelBridgeController
{
    private readonly AssetSyncRunner? _assetSync;
    private readonly Sync.DevicePairingService? _pairing;
    internal Func<string, JsonElement?, CancellationToken, Task<object?>>? PairingForVerify { get; set; }
    private async Task<object?> PairingRequest(string method, JsonElement? p, CancellationToken token)
    {
        if (PairingForVerify is { } verify) return await verify(method, p, token);
        switch (method)
        {
            case "status": return _pairing is not null ? await _pairing.Status(token) : new { available = false, devices = Array.Empty<object>(), session = new { phase = "idle" }, error = (string?)null };
            case "invite": return await Pairing.Start("invite", null, token);
            case "join": return await Pairing.Start("join", ReadRequiredString(p, "code"), token);
            case "approve": return await Pairing.Approve(ReadRequiredString(p, "approvalId"), token);
            case "cancel": return await Pairing.Cancel(token);
            case "remove": await Pairing.Remove(ReadRequiredString(p, "deviceId"), token); return await Pairing.Status(token);
            default: throw new InvalidOperationException("未対応の操作です。");
        }
    }
    internal void CancelDevicePairing() { if (_pairing is not null) _ = _pairing.Cancel(CancellationToken.None); }
    private Sync.DevicePairingService Pairing => _pairing ?? throw new InvalidOperationException("検証中は外部端末へ接続できません。");

    internal Func<bool, string?>? AssetSyncFolderPickerForVerify { get; set; }
    private async Task<object?> ConfigureAssetSyncAsync(JsonElement? parameters, CancellationToken token)
    {
        var create = ReadRequiredBool(parameters, "createGroup");
        string? path;
        if (AssetSyncFolderPickerForVerify is { } picker) path = picker(create);
        else
        {
            var dialog = new Microsoft.Win32.OpenFolderDialog
            {
                Title = CurrentSettings.Language == AppLanguage.English
                    ? (create ? "New empty sync folder" : "Existing shared sync folder")
                    : (create ? "新しい同期グループの空フォルダ" : "同期グループの共有フォルダ")
            };
            path = dialog.ShowDialog() == true ? dialog.FolderName : null;
        }
        if (path is not null)
        {
            await AssetLibrary.ConfigureSyncAsync(path, create, token);
            await AssetLibrary.SetSyncEnabledAsync(true, token);
            return await AssetLibrary.SyncOnceAsync(token, onlyWhenEnabled: true);
        }
        return await AssetLibrary.GetSyncStatusAsync(token);
    }
    private async Task<object?> EnableAssetSyncAsync(JsonElement? parameters, CancellationToken token)
    {
        await AssetLibrary.SetSyncEnabledAsync(ReadRequiredBool(parameters, "enabled"), token);
        return await AssetLibrary.GetSyncStatusAsync(token);
    }
    private async Task<object?> ResolveAssetSyncAsync(JsonElement? parameters, CancellationToken token) =>
        await AssetLibrary.ResolveSyncConflictAsync(ReadRequiredString(parameters, "revision"), ReadRequiredBool(parameters, "useRemote"), token);
}
