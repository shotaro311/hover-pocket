using System.Net;
using System.Net.Http.Json;
using System.Text.Json.Nodes;
using System.Xml.Linq;
using HoverPocket.Assets;

namespace HoverPocket.Shell.Sync;

internal sealed record LinkPlan(string DeviceId, string? GroupId, string? FolderId, string? Path);
internal sealed record LinkedDevice(string Id, string Name, bool Connected);

// The native host alone reads the loopback API credential. It never enters bridge state.
internal sealed class SyncthingLibraryLink : IDisposable
{
    private readonly HttpClient _http;
    internal SyncthingLibraryLink(HttpClient http) => _http = http;
    internal static SyncthingLibraryLink Open()
    {
        var path = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Syncthing", "config.xml");
        var gui = XDocument.Load(path).Root?.Element("gui") ?? throw new IOException("Syncthingを起動してください。");
        var address = gui.Element("address")?.Value ?? "";
        var uri = new Uri((gui.Attribute("tls")?.Value == "true" ? "https://" : "http://") + address + "/rest/");
        if (!uri.IsLoopback || !string.IsNullOrEmpty(uri.UserInfo)) throw new IOException("Syncthingの管理画面をこの端末内だけで接続できる設定にしてください。");
        var key = gui.Element("apikey")?.Value;
        if (string.IsNullOrWhiteSpace(key)) throw new IOException("Syncthingの接続設定を確認してください。");
        var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false, UseProxy = false }) { BaseAddress = uri, Timeout = TimeSpan.FromSeconds(10), MaxResponseContentBufferSize = 4 * 1024 * 1024 };
        client.DefaultRequestHeaders.Add("X-API-Key", key);
        return new(client);
    }
    private async Task<JsonNode> Get(string endpoint, CancellationToken token) =>
        JsonNode.Parse(await _http.GetStringAsync(endpoint, token)) ?? throw new IOException("同期の設定を読み取れません。");
    private async Task Put(string endpoint, JsonNode value, CancellationToken token)
    {
        using var response = await _http.PutAsJsonAsync(endpoint, value, token);
        if (!response.IsSuccessStatusCode) throw new IOException("同期の設定を保存できません。");
    }
    private async Task Post(string endpoint, JsonNode value, CancellationToken token)
    {
        using var response = await _http.PostAsJsonAsync(endpoint, value, token);
        if (!response.IsSuccessStatusCode) throw new IOException("同期の設定を追加できません。");
    }
    internal async Task<LinkPlan> Plan(AssetSyncStatus status, CancellationToken token)
    {
        var id = (await Get("system/status", token))["myID"]?.GetValue<string>() ?? throw new IOException("端末を確認できません。");
        if (!status.Configured) return new(id, null, null, null);
        var folders = (await Get("config/folders", token)).AsArray();
        var matches = folders.Where(f => SamePath(f?["path"]?.GetValue<string>(), status.TransportPath)).ToArray();
        if (matches.Length != 1 || matches[0]?["type"]?.GetValue<string>() != "sendreceive")
            throw new IOException("現在のライブラリ専用共有を確認できません。詳細設定を確認してください。");
        return new(id, status.GroupId, matches[0]!["id"]!.GetValue<string>(), status.TransportPath);
    }
    internal async Task<LinkedDevice[]> Devices(LinkPlan plan, CancellationToken token)
    {
        if (plan.FolderId is null) return [];
        var folder = await Get("config/folders/" + Uri.EscapeDataString(plan.FolderId), token);
        var devices = (await Get("config/devices", token)).AsArray();
        var connections = (await Get("system/connections", token))["connections"];
        return folder["devices"]!.AsArray().Select(d => d!["deviceID"]!.GetValue<string>()).Where(id => id != plan.DeviceId)
            .Select(id => new LinkedDevice(id, devices.FirstOrDefault(d => d?["deviceID"]?.GetValue<string>() == id)?["name"]?.GetValue<string>() ?? "端末", connections?[id]?["connected"]?.GetValue<bool>() == true)).ToArray();
    }
    internal static bool SamePath(string? a, string? b) => a is not null && b is not null &&
        System.IO.Path.GetFullPath(a).TrimEnd('\\','/').Equals(System.IO.Path.GetFullPath(b).TrimEnd('\\','/'), StringComparison.OrdinalIgnoreCase);
    internal static void SafePath(string path)
    {
        for (var p = System.IO.Path.GetFullPath(path); !string.IsNullOrEmpty(p); p = System.IO.Path.GetDirectoryName(p))
            if (System.IO.Path.Exists(p) && (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("同期先にリンクされたフォルダは使用できません。");
    }
    internal static void PrepareMarker(LinkPlan plan)
    {
        SafePath(plan.Path!);
        Directory.CreateDirectory(plan.Path!);
        var marker = System.IO.Path.Combine(plan.Path!, "hoverpocket-sync.json"); SafePath(marker);
        if (File.Exists(marker))
        {
            if (new FileInfo(marker).Length > 1024) throw new IOException("同期グループを確認できません。");
            var node = JsonNode.Parse(File.ReadAllText(marker));
            if (node?["version"]?.GetValue<int>() != 1 || node?["groupId"]?.GetValue<string>() != plan.GroupId) throw new IOException("別のライブラリが保存されています。");
            return;
        }
        if (Directory.EnumerateFileSystemEntries(plan.Path!).Any(p => System.IO.Path.GetFileName(p) is not (".stfolder" or ".stignore")))
            throw new IOException("同期先に既存のファイルがあります。");
        using var file = new FileStream(marker, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        System.Text.Json.JsonSerializer.Serialize(file, new { version = 1, groupId = plan.GroupId });
    }
    internal async Task<bool> Add(LinkPlan plan, string peerId, string peerName, CancellationToken token)
    {
        var folders = (await Get("config/folders", token)).AsArray();
        var folder = folders.FirstOrDefault(f => f?["id"]?.GetValue<string>() == plan.FolderId)?.DeepClone();
        if (folder is not null && (!SamePath(folder["path"]?.GetValue<string>(), plan.Path) || folder["type"]?.GetValue<string>() != "sendreceive"))
            throw new IOException("同じIDの別の共有が存在します。");
        if (folders.Any(f => f?["id"]?.GetValue<string>() != plan.FolderId && SamePath(f?["path"]?.GetValue<string>(), plan.Path)))
            throw new IOException("この保存先は別の共有で使用されています。");
        var devices = (await Get("config/devices", token)).AsArray();
        if (!devices.Any(d => d?["deviceID"]?.GetValue<string>() == peerId))
        {
            var device = await Get("config/defaults/device", token);
            device["deviceID"] = peerId; device["name"] = peerName; device["addresses"] = new JsonArray("dynamic");
            device["introducer"] = false; device["autoAcceptFolders"] = false;
            await Post("config/devices", device, token);
        }
        if (folder is null)
        {
            folder = await Get("config/defaults/folder", token);
            folder["id"] = plan.FolderId; folder["label"] = "HoverPocket Library"; folder["path"] = plan.Path;
            folder["type"] = "sendreceive"; folder["paused"] = false;
            folder["devices"] = new JsonArray(new JsonObject { ["deviceID"] = plan.DeviceId });
        }
        var peers = folder["devices"]!.AsArray();
        if (peers.Any(d => d?["deviceID"]?.GetValue<string>() == peerId)) return false;
        peers.Add(new JsonObject { ["deviceID"] = peerId });
        await Post("config/folders", folder, token);
        var readback = await Get("config/folders/" + Uri.EscapeDataString(plan.FolderId!), token);
        if (!SamePath(readback["path"]?.GetValue<string>(), plan.Path) || !readback["devices"]!.AsArray().Any(d => d?["deviceID"]?.GetValue<string>() == peerId))
            throw new IOException("共有の保存を確認できません。");
        return true;
    }
    internal async Task Remove(LinkPlan plan, string peerId, CancellationToken token)
    {
        if (peerId == plan.DeviceId || plan.FolderId is null) throw new IOException("この端末は解除できません。");
        var endpoint = "config/folders/" + Uri.EscapeDataString(plan.FolderId);
        JsonNode folder;
        try { folder = await Get(endpoint, token); }
        catch (HttpRequestException ex) when (ex.StatusCode == HttpStatusCode.NotFound) { return; }
        if (!SamePath(folder["path"]?.GetValue<string>(), plan.Path)) throw new IOException("共有先が変わったため中止しました。");
        var peers = folder["devices"]!.AsArray();
        for (int i = peers.Count - 1; i >= 0; i--) if (peers[i]?["deviceID"]?.GetValue<string>() == peerId) peers.RemoveAt(i);
        await Put(endpoint, folder, token);
        if ((await Get(endpoint, token))["devices"]!.AsArray().Any(d => d?["deviceID"]?.GetValue<string>() == peerId)) throw new IOException("解除を確認できません。");
    }
    public void Dispose() => _http.Dispose();
}
