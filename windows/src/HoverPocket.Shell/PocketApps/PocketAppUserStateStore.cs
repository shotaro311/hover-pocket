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
    private Dictionary<string, string> _state;

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

    public IReadOnlyDictionary<string, string> Snapshot()
    {
        lock (_sync)
        {
            return new Dictionary<string, string>(_state, StringComparer.Ordinal);
        }
    }

    public void SetString(string key, string? value)
    {
        if (!_allowedKeys.Contains(key))
        {
            throw new PocketAppUserStateStoreException("state_key");
        }
        if (value is not null && value.EnumerateRunes().Count() > MaximumValueScalars)
        {
            throw new PocketAppUserStateStoreException("state_value");
        }
        lock (_sync)
        {
            var previous = new Dictionary<string, string>(_state, StringComparer.Ordinal);
            if (value is null)
            {
                _state.Remove(key);
            }
            else
            {
                _state[key] = value;
            }
            var temporaryPath = $"{_filePath}.{Guid.NewGuid():N}.tmp";
            try
            {
                var data = JsonSerializer.SerializeToUtf8Bytes(
                    new SortedDictionary<string, string>(_state, StringComparer.Ordinal));
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

    private Dictionary<string, string> Load()
    {
        if (!File.Exists(_filePath))
        {
            return new Dictionary<string, string>(StringComparer.Ordinal);
        }
        try
        {
            var data = File.ReadAllBytes(_filePath);
            if (data.Length > MaximumDocumentBytes)
            {
                throw new PocketAppUserStateStoreException("state_size");
            }
            var values = JsonSerializer.Deserialize<Dictionary<string, string>>(data)
                ?? throw new PocketAppUserStateStoreException("state_document");
            if (!values.Keys.All(_allowedKeys.Contains)
                || values.Values.Any(value => value is null || value.EnumerateRunes().Count() > MaximumValueScalars))
            {
                throw new PocketAppUserStateStoreException("state_document");
            }
            return new Dictionary<string, string>(values, StringComparer.Ordinal);
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
}
