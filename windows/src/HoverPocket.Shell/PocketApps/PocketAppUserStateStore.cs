using System.Globalization;
using System.Text;
using System.Text.Json;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppUserStateStoreException(string message) : Exception(message);

internal sealed class PocketAppUserStateStore : IDisposable
{
    public const int MaximumDocumentBytes = 256 * 1024;
    public const int MaximumValueScalars = 4_096;

    private readonly object _sync = new();
    private readonly IReadOnlySet<string> _allowedKeys;
    private readonly IReadOnlyDictionary<string, PocketAppStatePropertySchema> _stateProperties;
    private readonly PocketAppPinnedDirectory _rootDirectory;
    private readonly PocketAppPinnedDirectory _packageDirectory;
    private readonly string _filePath;
    private Dictionary<string, JsonElement> _state;
    private bool _disposed;

    public PocketAppUserStateStore(
        string packageId,
        IReadOnlySet<string> allowedKeys,
        string rootDirectory)
        : this(
            packageId,
            allowedKeys.ToDictionary(
                key => key,
                _ => new PocketAppStatePropertySchema(
                    new HashSet<string>(["string", "integer", "number", "boolean", "null"], StringComparer.Ordinal),
                    false,
                    null,
                    null),
                StringComparer.Ordinal),
            rootDirectory)
    {
    }

    public PocketAppUserStateStore(
        string packageId,
        IReadOnlyDictionary<string, IReadOnlySet<string>> propertyTypes,
        string rootDirectory)
        : this(
            packageId,
            propertyTypes.ToDictionary(
                item => item.Key,
                item => new PocketAppStatePropertySchema(item.Value, false, null, null),
                StringComparer.Ordinal),
            rootDirectory)
    {
    }

    public PocketAppUserStateStore(
        string packageId,
        IReadOnlyDictionary<string, PocketAppStatePropertySchema> stateProperties,
        string rootDirectory)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(
                packageId,
                "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$",
                System.Text.RegularExpressions.RegexOptions.CultureInvariant))
        {
            throw new PocketAppUserStateStoreException("package_id");
        }
        _allowedKeys = stateProperties.Keys.ToHashSet(StringComparer.Ordinal);
        _stateProperties = stateProperties;
        var packageDirectory = Path.Combine(rootDirectory, packageId);
        PocketAppPinnedDirectory? rootPin = null;
        PocketAppPinnedDirectory? packagePin = null;
        try
        {
            rootPin = new PocketAppPinnedDirectory(rootDirectory, allowReplacement: false);
            packagePin = new PocketAppPinnedDirectory(packageDirectory, allowReplacement: false);
            _rootDirectory = rootPin;
            _packageDirectory = packagePin;
            _filePath = Path.Combine(packageDirectory, "state.json");
            var loaded = Load();
            _state = loaded.State;
            if (loaded.NeedsRepair)
            {
                Persist();
            }
        }
        catch
        {
            packagePin?.Dispose();
            rootPin?.Dispose();
            throw new PocketAppUserStateStoreException("state_persistence");
        }
    }

    public IReadOnlyDictionary<string, JsonElement> Snapshot()
    {
        lock (_sync)
        {
            RequireActive();
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
            ValidateValue(value.Value, _stateProperties[key]);
        }
        else if (_stateProperties[key].IsRequired)
        {
            throw new PocketAppUserStateStoreException("state_value");
        }
        lock (_sync)
        {
            RequireActive();
            var previous = new Dictionary<string, JsonElement>(_state, StringComparer.Ordinal);
            if (value is null)
            {
                _state.Remove(key);
            }
            else
            {
                _state[key] = value.Value.Clone();
            }
            try
            {
                Persist();
            }
            catch (Exception ex)
            {
                _state = previous;
                if (ex is PocketAppUserStateStoreException)
                {
                    throw;
                }
                throw new PocketAppUserStateStoreException("state_persistence");
            }
        }
    }

    private (Dictionary<string, JsonElement> State, bool NeedsRepair) Load()
    {
        try
        {
            RequireActive();
            _rootDirectory.Validate();
            using var handle = _packageDirectory.OpenFileForRead("state.json");
            if (handle is null)
            {
                return (new Dictionary<string, JsonElement>(StringComparer.Ordinal), false);
            }
            using var stream = new FileStream(handle, FileAccess.Read);
            if (stream.Length < 0 || stream.Length > MaximumDocumentBytes)
            {
                throw new PocketAppUserStateStoreException("state_size");
            }
            using var buffer = new MemoryStream((int)stream.Length);
            stream.CopyTo(buffer);
            var data = buffer.ToArray();
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
            var needsRepair = false;
            foreach (var property in document.RootElement.EnumerateObject())
            {
                if (!_stateProperties.TryGetValue(property.Name, out var stateProperty))
                {
                    needsRepair = true;
                    continue;
                }
                try
                {
                    ValidateValue(property.Value, stateProperty);
                    values.Add(property.Name, property.Value.Clone());
                }
                catch (PocketAppUserStateStoreException)
                {
                    needsRepair = true;
                }
            }
            if (_stateProperties.Any(item => item.Value.IsRequired && !values.ContainsKey(item.Key)))
            {
                needsRepair = true;
            }
            _packageDirectory.Validate();
            _rootDirectory.Validate();
            return (values, needsRepair);
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

    public void Dispose()
    {
        lock (_sync)
        {
            if (_disposed) { return; }
            _disposed = true;
            _packageDirectory.Dispose();
            _rootDirectory.Dispose();
        }
    }

    private void RequireActive()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    private void Persist()
    {
        var temporaryPath = $"{_filePath}.{Guid.NewGuid():N}.tmp";
        try
        {
            var data = JsonSerializer.SerializeToUtf8Bytes(
                new SortedDictionary<string, JsonElement>(_state, StringComparer.Ordinal));
            if (data.Length > MaximumDocumentBytes)
            {
                throw new PocketAppUserStateStoreException("state_size");
            }
            _rootDirectory.Validate();
            _packageDirectory.Validate();
            using (var stream = new FileStream(
                       temporaryPath,
                       FileMode.CreateNew,
                       FileAccess.Write,
                       FileShare.None,
                       bufferSize: 16_384,
                       FileOptions.WriteThrough))
            {
                stream.Write(data);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporaryPath, _filePath, overwrite: true);
            _packageDirectory.Validate();
            _rootDirectory.Validate();
        }
        catch (Exception ex)
        {
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

    private static void ValidateValue(JsonElement value, PocketAppStatePropertySchema property)
    {
        var acceptedTypes = property.Types;
        switch (value.ValueKind)
        {
            case JsonValueKind.String:
                var text = value.GetString() ?? string.Empty;
                var scalarCount = text.EnumerateRunes().Count();
                if (scalarCount > MaximumValueScalars
                    || (property.MaximumLength is { } maximumLength && scalarCount > maximumLength)
                    || (property.Format == "date" && !DateOnly.TryParseExact(
                        text,
                        "yyyy-MM-dd",
                        CultureInfo.InvariantCulture,
                        DateTimeStyles.None,
                        out _)))
                {
                    throw new PocketAppUserStateStoreException("state_value");
                }
                RequireType(acceptedTypes.Contains("string"));
                return;
            case JsonValueKind.Number:
                if (value.GetRawText().Length > 128)
                {
                    throw new PocketAppUserStateStoreException("state_value");
                }
                var isInteger = value.TryGetDecimal(out var decimalValue)
                    && decimal.Truncate(decimalValue) == decimalValue;
                RequireType(acceptedTypes.Contains("number") || (isInteger && acceptedTypes.Contains("integer")));
                return;
            case JsonValueKind.True:
            case JsonValueKind.False:
                RequireType(acceptedTypes.Contains("boolean"));
                return;
            case JsonValueKind.Null:
                RequireType(acceptedTypes.Contains("null"));
                return;
            default:
                throw new PocketAppUserStateStoreException("state_value");
        }
    }

    private static void RequireType(bool condition)
    {
        if (!condition)
        {
            throw new PocketAppUserStateStoreException("state_value");
        }
    }
}
