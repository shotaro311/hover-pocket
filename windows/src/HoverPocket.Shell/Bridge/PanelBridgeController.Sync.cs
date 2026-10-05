using System.Text.Json;
using HoverPocket.Assets;
using HoverPocket.Shell.Configuration;

namespace HoverPocket.Shell.Bridge;

internal sealed partial class PanelBridgeController
{
    private readonly AssetSyncRunner? _assetSync;
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
