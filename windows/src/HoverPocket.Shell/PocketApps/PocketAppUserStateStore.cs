using System.Text;
using System.Text.Json;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppUserStateStoreException(string message) : Exception(message);

internal sealed class PocketAppUserStateStore
{
    public const int MaximumDocumentBytes = 256 * 1024;
    public const int MaximumValueScalars = 4_096;

    private readonly object _sync = new();
    private readonly IReadOnlySet<string> _allowedKeys;
    private readonly string _filePath;
    private Dictionary<string, JsonElement> _state;

    public PocketAppUserStateStore(
        string packageId,
        IReadOnlySet<string> allowedKeys,
        string rootDirectory)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(
                packageId,
                "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$",
                System.Text.RegularExpressions.RegexOptions.CultureInvariant))
        {
            throw new PocketAppUserStateStoreException("package_id");
        }
        _allowedKeys = allowedKeys;
        var packageDirectory = Path.Combine(rootDirectory, packageId);
        Directory.CreateDirectory(packageDirectory);
        _filePath = Path.Combine(packageDirectory, "state.json");
        _state = Load();
    }

    public IReadOnlyDictionary<string, JsonElement> Snapshot()
    {
        lock (_sync)
        {
            return _state.ToDictionary(
                item => item.Key,
                item => item.Value.Clone(),
                StringComparer.Ordinal);
        }
    }

    public void SetString(string key, string? value)
    {
        SetValue(
            key,
            value is null ? null : JsonSerializer.SerializeToElement(value));
    }

    public void SetValue(string key, JsonElement? value)
    {
        if (!_allowedKeys.Contains(key))
        {
            throw new PocketAppUserStateStoreException("state_key");
        }
        if (value is not null)
        {
            ValidateValue(value.Value);
        }
        lock (_sync)
        {
            var previous = new Dictionary<string, JsonElement>(_state, StringComparer.Ordinal);
            if (value is null)
            {
                _state.Remove(key);
            }
            else
            {
                _state[key] = value.Value.Clone();
            }
            var temporaryPath = $"{_filePath}.{Guid.NewGuid():N}.tmp";
            try
            {
                var data = JsonSerializer.SerializeToUtf8Bytes(
                    new SortedDictionary<string, JsonElement>(_state, StringComparer.Ordinal));
                if (data.Length > MaximumDocumentBytes)
                {
                    throw new PocketAppUserStateStoreException("state_size");
                }
                File.WriteAllBytes(temporaryPath, data);
                File.Move(temporaryPath, _filePath, overwrite: true);
            }
            catch (Exception ex)
            {
                _state = previous;
                try
                {
                    if (File.Exists(temporaryPath))
                    {
                        File.Delete(temporaryPath);
                    }
                }
                catch
                {
                }
                if (ex is PocketAppUserStateStoreException)
                {
                    throw;
                }
                throw new PocketAppUserStateStoreException("state_persistence");
            }
        }
    }

    private Dictionary<string, JsonElement> Load()
    {
        if (!File.Exists(_filePath))
        {
            return new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        }
        try
        {
            var data = File.ReadAllBytes(_filePath);
            if (data.Length > MaximumDocumentBytes)
            {
                throw new PocketAppUserStateStoreException("state_size");
            }
            using var document = JsonDocument.Parse(data);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                throw new PocketAppUserStateStoreException("state_document");
            }
            var values = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
            foreach (var property in document.RootElement.EnumerateObject())
            {
                if (!_allowedKeys.Contains(property.Name))
                {
                    throw new PocketAppUserStateStoreException("state_document");
                }
                ValidateValue(property.Value);
                values.Add(property.Name, property.Value.Clone());
            }
            return values;
        }
        catch (PocketAppUserStateStoreException)
        {
            throw;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            throw new PocketAppUserStateStoreException("state_document");
        }
    }

    private static void ValidateValue(JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.String:
                if ((value.GetString() ?? string.Empty).EnumerateRunes().Count() > MaximumValueScalars)
                {
                    throw new PocketAppUserStateStoreException("state_value");
                }
                return;
            case JsonValueKind.Number:
                if (value.GetRawText().Length > 128)
                {
                    throw new PocketAppUserStateStoreException("state_value");
                }
                return;
            case JsonValueKind.True:
            case JsonValueKind.False:
            case JsonValueKind.Null:
                return;
            default:
                throw new PocketAppUserStateStoreException("state_value");
        }
    }
}
