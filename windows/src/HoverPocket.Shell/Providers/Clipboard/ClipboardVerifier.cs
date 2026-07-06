using System.IO;
using System.Text.Json;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Verification;
using WpfDataFormats = System.Windows.DataFormats;

namespace HoverPocket.Shell.Providers.Clipboard;

internal sealed class ClipboardVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "HoverPocketClipboardVerify", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            VerifyCrud(root);
            VerifyTrim(root);
            VerifyFavoritesAndLegacyCompatibility(root);
            VerifyPngNormalizationAndDedup(root);
            VerifyPersistenceAndRestore(root);
            VerifyCorruptJsonRecovery(root);
            VerifyPrivateModeTransitions(root).GetAwaiter().GetResult();
            VerifyDragDataFormats(root);
        }
        finally
        {
            try
            {
                Directory.Delete(root, recursive: true);
            }
            catch (IOException)
            {
            }
        }

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS clipboard verify: CRUD, limits, favorites, legacy defaults, PNG normalization, dedup, persistence, corrupt fallback, private mode");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL clipboard verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private void VerifyCrud(string root)
    {
        var store = NewStore(root, "crud");
        store.AddText("hello clipboard");
        store.AddImage(ClipboardHistoryStore.CreateProbeBitmap());
        if (store.TextItems.Count != 1 || store.ImageItems.Count != 1)
        {
            _failures.Add("CRUD: text and image were not added");
        }

        var imagePath = store.ImagePath(store.ImageItems[0]);
        if (!File.Exists(imagePath))
        {
            _failures.Add("CRUD: image PNG file was not written");
        }

        store.Clear();
        if (store.TextItems.Count != 0 || store.ImageItems.Count != 0)
        {
            _failures.Add("CRUD: clear did not remove history items");
        }

        if (File.Exists(imagePath))
        {
            _failures.Add("CRUD: clear did not remove image PNG file");
        }
    }

    private void VerifyTrim(string root)
    {
        var store = NewStore(root, "trim");
        for (var index = 0; index < ClipboardHistoryStore.MaxTextItems + 5; index++)
        {
            store.AddText($"text-{index}");
        }

        for (var index = 0; index < ClipboardHistoryStore.MaxImageItems + 4; index++)
        {
            store.AddImage(ClipboardHistoryStore.CreateProbeBitmap(index + 1));
        }

        if (store.TextItems.Count != ClipboardHistoryStore.MaxTextItems)
        {
            _failures.Add("trim: text history was not capped at 30");
        }

        if (store.ImageItems.Count != ClipboardHistoryStore.MaxImageItems)
        {
            _failures.Add("trim: image history was not capped at 20");
        }

        var pngCount = Directory.GetFiles(store.StorageDirectory, "*.png").Length;
        if (pngCount != ClipboardHistoryStore.MaxImageItems)
        {
            _failures.Add($"trim: expected 20 PNG files after image trim, got {pngCount}");
        }
    }

    private void VerifyFavoritesAndLegacyCompatibility(string root)
    {
        var store = NewStore(root, "favorites");
        store.AddText("favorite text");
        store.ToggleFavorite(ClipboardHistoryItemKind.Text, store.TextItems[0].Id);
        store.AddText("regular text");
        store.AddImage(ClipboardHistoryStore.CreateProbeBitmap(40));
        store.ToggleFavorite(ClipboardHistoryItemKind.Image, store.ImageItems[0].Id);
        var favoriteImage = store.ImageItems[0];
        var favoriteImagePath = store.ImagePath(favoriteImage);
        store.AddImage(ClipboardHistoryStore.CreateProbeBitmap(41));
        var regularImagePath = store.ImagePath(store.ImageItems[0]);

        store.Clear();
        if (store.TextItems.Count != 1
            || store.TextItems[0].Text != "favorite text"
            || !store.TextItems[0].Favorite
            || store.ImageItems.Count != 1
            || !store.ImageItems[0].Favorite)
        {
            _failures.Add("favorites: clear did not preserve favorite text and image only");
        }

        if (File.Exists(regularImagePath))
        {
            _failures.Add("favorites: clear did not delete non-favorite image file");
        }

        if (!File.Exists(favoriteImagePath))
        {
            _failures.Add("favorites: clear deleted favorite image file");
        }

        store.DeleteItem(ClipboardHistoryItemKind.Image, store.ImageItems[0].Id);
        if (store.ImageItems.Count != 0 || File.Exists(favoriteImagePath))
        {
            _failures.Add("favorites: explicit favorite image delete did not remove item and PNG");
        }

        var trimStore = NewStore(root, "favorite-trim");
        trimStore.AddText("keep text");
        var favoriteTextId = trimStore.TextItems[0].Id;
        trimStore.ToggleFavorite(ClipboardHistoryItemKind.Text, favoriteTextId);
        for (var index = 0; index < ClipboardHistoryStore.MaxTextItems + 5; index++)
        {
            trimStore.AddText($"bulk-text-{index}");
        }

        if (!trimStore.TextItems.Any(item => item.Id == favoriteTextId && item.Favorite))
        {
            _failures.Add("favorites: text trim removed a favorite item");
        }

        trimStore.AddImage(ClipboardHistoryStore.CreateProbeBitmap(60));
        var favoriteImageId = trimStore.ImageItems[0].Id;
        var preservedImagePath = trimStore.ImagePath(trimStore.ImageItems[0]);
        trimStore.ToggleFavorite(ClipboardHistoryItemKind.Image, favoriteImageId);
        for (var index = 0; index < ClipboardHistoryStore.MaxImageItems + 4; index++)
        {
            trimStore.AddImage(ClipboardHistoryStore.CreateProbeBitmap(61 + index));
        }

        if (!trimStore.ImageItems.Any(item => item.Id == favoriteImageId && item.Favorite)
            || !File.Exists(preservedImagePath))
        {
            _failures.Add("favorites: image trim removed a favorite item or PNG");
        }

        VerifyLegacyFavoriteDefaults(root);
    }

    private void VerifyLegacyFavoriteDefaults(string root)
    {
        var directory = Path.Combine(root, "legacy-favorite");
        Directory.CreateDirectory(directory);
        var imageFileName = $"{Guid.NewGuid():N}.png";
        var seeded = new ClipboardHistoryStore(directory);
        seeded.AddImage(ClipboardHistoryStore.CreateProbeBitmap(70));
        File.Copy(seeded.ImagePath(seeded.ImageItems[0]), Path.Combine(directory, imageFileName), overwrite: true);
        File.WriteAllText(
            Path.Combine(directory, "history.json"),
            $$"""
            {
              "textItems": [
                {
                  "id": "{{Guid.NewGuid()}}",
                  "text": "legacy text",
                  "createdAt": "{{DateTimeOffset.UtcNow:o}}"
                }
              ],
              "imageItems": [
                {
                  "id": "{{Guid.NewGuid()}}",
                  "fileName": "{{imageFileName}}",
                  "contentHash": "{{new string('a', 64)}}",
                  "width": 48,
                  "height": 48,
                  "createdAt": "{{DateTimeOffset.UtcNow:o}}"
                }
              ]
            }
            """);

        var restored = new ClipboardHistoryStore(directory);
        if (restored.TextItems.Count != 1
            || restored.TextItems[0].Favorite
            || restored.ImageItems.Count != 1
            || restored.ImageItems[0].Favorite)
        {
            _failures.Add("legacy favorite: missing favorite fields did not default to false");
        }
    }

    private void VerifyPngNormalizationAndDedup(string root)
    {
        var store = NewStore(root, "png");
        var image = ClipboardHistoryStore.CreateProbeBitmap(12);
        store.AddImage(image);
        store.AddImage(image);

        if (store.ImageItems.Count != 1)
        {
            _failures.Add("PNG dedup: duplicate image hash was inserted twice");
            return;
        }

        var item = store.ImageItems[0];
        var path = store.ImagePath(item);
        var bytes = File.ReadAllBytes(path);
        var isPng = bytes.Length > 8
            && bytes[0] == 0x89
            && bytes[1] == 0x50
            && bytes[2] == 0x4E
            && bytes[3] == 0x47;
        if (!isPng || item.ContentHash.Length != 64)
        {
            _failures.Add("PNG normalization: image was not saved as hashed PNG");
        }
    }

    private void VerifyPersistenceAndRestore(string root)
    {
        var directory = Path.Combine(root, "restore");
        var store = new ClipboardHistoryStore(directory);
        store.AddText("persisted text");
        store.AddImage(ClipboardHistoryStore.CreateProbeBitmap(21));

        var restored = new ClipboardHistoryStore(directory);
        if (restored.TextItems.Count != 1
            || restored.TextItems[0].Text != "persisted text"
            || restored.ImageItems.Count != 1
            || !File.Exists(restored.ImagePath(restored.ImageItems[0])))
        {
            _failures.Add("persistence: history did not restore from history.json and PNG files");
        }
    }

    private void VerifyCorruptJsonRecovery(string root)
    {
        var directory = Path.Combine(root, "corrupt");
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "history.json"), "{ not valid json");
        var store = new ClipboardHistoryStore(directory);
        if (store.TextItems.Count != 0
            || store.ImageItems.Count != 0
            || string.IsNullOrWhiteSpace(store.LastErrorMessage))
        {
            _failures.Add("corrupt JSON: defaults were not restored with an error message");
        }
    }

    private async Task VerifyPrivateModeTransitions(string root)
    {
        var currentSettings = UserSettingsStore.CreateDefault(["clipboard"]);
        currentSettings.ClipboardPrivateMode = false;
        var monitor = new FakeClipboardMonitor();
        ClipboardBridgeController? controller = null;
        controller = new ClipboardBridgeController(
            NewStore(root, "private"),
            monitor,
            () => currentSettings,
            (enabled, _) =>
            {
                currentSettings.ClipboardPrivateMode = enabled;
                controller!.ApplySettings(currentSettings, providerVisible: true);
                return Task.FromResult<object?>(controller.BuildState());
            },
            () => true);
        using (controller)
        {
            controller.ApplySettings(currentSettings, providerVisible: true);
            if (!monitor.IsListening)
            {
                _failures.Add("private mode: monitor did not start when provider was visible");
            }

            var dispatcher = new BridgeDispatcher();
            controller.Attach(dispatcher);
            await Send(dispatcher, """{"id":"1","method":"clipboard.setPrivateMode","params":{"enabled":true}}""");
            if (monitor.IsListening)
            {
                _failures.Add("private mode: monitor did not stop when private mode was enabled");
            }

            await Send(dispatcher, """{"id":"2","method":"clipboard.setPrivateMode","params":{"enabled":false}}""");
            if (!monitor.IsListening)
            {
                _failures.Add("private mode: monitor did not restart when private mode was disabled");
            }

            controller.ApplySettings(currentSettings, providerVisible: false);
            if (monitor.IsListening)
            {
                _failures.Add("private mode: monitor did not stop when provider visibility was off");
            }
        }
    }

    private void VerifyDragDataFormats(string root)
    {
        var store = NewStore(root, "drag");
        store.AddText("drag text");
        store.AddImage(ClipboardHistoryStore.CreateProbeBitmap(33));
        var textData = store.BuildDragDataObject(ClipboardHistoryItemKind.Text, store.TextItems[0].Id);
        var imageData = store.BuildDragDataObject(ClipboardHistoryItemKind.Image, store.ImageItems[0].Id);

        if (textData?.GetDataPresent(WpfDataFormats.UnicodeText) != true)
        {
            _failures.Add("drag: text payload did not expose UnicodeText");
        }

        if (imageData?.GetDataPresent(WpfDataFormats.Bitmap) != true
            || imageData.GetDataPresent(WpfDataFormats.FileDrop) != true)
        {
            _failures.Add("drag: image payload did not expose Bitmap and FileDrop");
        }
    }

    private static ClipboardHistoryStore NewStore(string root, string name)
    {
        return new ClipboardHistoryStore(Path.Combine(root, name));
    }

    private static async Task<string> Send(BridgeDispatcher dispatcher, string request)
    {
        var response = await dispatcher.ProcessRawMessageAsync(request);
        if (string.IsNullOrWhiteSpace(response))
        {
            throw new InvalidOperationException("Bridge did not return a response.");
        }

        using var document = JsonDocument.Parse(response);
        if (document.RootElement.TryGetProperty("error", out var error)
            && error.ValueKind != JsonValueKind.Null)
        {
            throw new InvalidOperationException(error.GetRawText());
        }

        return response;
    }

    private sealed class FakeClipboardMonitor : IClipboardMonitor
    {
        public event EventHandler? ClipboardUpdated;

        public bool IsListening { get; private set; }

        public void Start()
        {
            IsListening = true;
        }

        public void Stop()
        {
            IsListening = false;
        }

        public void Dispose()
        {
            Stop();
        }

        public void RaiseUpdated()
        {
            ClipboardUpdated?.Invoke(this, EventArgs.Empty);
        }
    }
}
