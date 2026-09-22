using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Bridge;

namespace HoverPocket.Shell.Providers.Weather;

internal sealed class WeatherStore(string rootDirectory, WeatherService? service = null)
{
    private readonly WeatherService _service = service ?? new WeatherService();
    private readonly SemaphoreSlim _gate = new(1, 1);

    public async Task<WeatherState> LoadAsync(WeatherLocation location, string unit, bool force, CancellationToken token)
    {
        var scale = location.ResolveScale(unit);
        // Coordinates are part of the cache identity, including successive current-location requests.
        var identity = JsonSerializer.Serialize(new { location.Id, location.Latitude, location.Longitude, scale });
        var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity)));
        var path = Path.Combine(rootDirectory, key + ".json");
        await _gate.WaitAsync(token);
        try
        {
            var cached = ReadCache(path, location.Id, scale);
            var age = cached is null ? TimeSpan.MaxValue : DateTimeOffset.UtcNow - cached.FetchedAt;
            if (!force && age >= TimeSpan.Zero && age < TimeSpan.FromMinutes(20))
                return new(location, scale, cached, false, null);
            try
            {
                var forecast = await _service.FetchAsync(location, scale, token);
                try
                {
                    Directory.CreateDirectory(rootDirectory);
                    var temporary = path + ".tmp";
                    await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(forecast, BridgeJson.Options), token);
                    File.Move(temporary, path, true);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    return new(location, scale, forecast, false, "cache_unavailable");
                }
                return new(location, scale, forecast, false, null);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
            catch (Exception error) when (error is HttpRequestException or OperationCanceledException or JsonException
                or InvalidOperationException or KeyNotFoundException or FormatException)
            {
                return new(location, scale, cached, cached is not null, "unavailable");
            }
        }
        finally { _gate.Release(); }
    }

    private static WeatherForecast? ReadCache(string path, string id, string scale)
    {
        try
        {
            if (!File.Exists(path) || new FileInfo(path).Length > 1_048_576) return null;
            var result = JsonSerializer.Deserialize<WeatherForecast>(File.ReadAllText(path), BridgeJson.Options);
            return result is { IsValid: true } && result.LocationID == id && result.TemperatureScale == scale ? result : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }
}
