using System.Globalization;
using System.Text.Json;

namespace HoverPocket.Shell.Providers.Weather;

internal sealed class WeatherService
{
    private static readonly HttpClient SharedClient = new() { Timeout = TimeSpan.FromSeconds(12) };
    private readonly HttpClient _client;

    public WeatherService(HttpClient? client = null) => _client = client ?? SharedClient;

    public static Uri ForecastUri(WeatherLocation location, string scale)
    {
        if (!location.IsValid || scale is not ("celsius" or "fahrenheit"))
            throw new ArgumentException("Invalid weather location or unit.");
        return new Uri("https://api.open-meteo.com/v1/forecast?latitude="
            + location.Latitude.ToString("F5", CultureInfo.InvariantCulture)
            + "&longitude=" + location.Longitude.ToString("F5", CultureInfo.InvariantCulture)
            + "&current=temperature_2m,weather_code&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
            + "&timezone=auto&forecast_days=8&temperature_unit=" + scale);
    }

    public async Task<WeatherForecast> FetchAsync(WeatherLocation location, string scale, CancellationToken token)
    {
        using var json = await GetJsonAsync(ForecastUri(location, scale), token);
        return Decode(json.RootElement, location.Id, scale);
    }

    internal static WeatherForecast Decode(JsonElement root, string locationId, string scale)
    {
        var current = root.GetProperty("current");
        var daily = root.GetProperty("daily");
        var fields = new[] { "time", "weather_code", "temperature_2m_max", "temperature_2m_min", "precipitation_probability_max" };
        if (fields.Any(field => daily.GetProperty(field).GetArrayLength() < 8))
            throw new JsonException("Incomplete forecast.");
        var days = Enumerable.Range(0, 8).Select(index => new WeatherDay(
            daily.GetProperty("time")[index].GetString()!,
            daily.GetProperty("weather_code")[index].GetInt32(),
            daily.GetProperty("temperature_2m_max")[index].GetDouble(),
            daily.GetProperty("temperature_2m_min")[index].GetDouble(),
            daily.GetProperty("precipitation_probability_max")[index].GetInt32())).ToArray();
        var forecast = new WeatherForecast(locationId, scale, root.GetProperty("timezone").GetString()!,
            DateTimeOffset.UtcNow, current.GetProperty("temperature_2m").GetDouble(),
            current.GetProperty("weather_code").GetInt32(), days);
        if (!forecast.IsValid) throw new JsonException("Invalid forecast.");
        return forecast;
    }

    public async Task<WeatherLocation[]> SearchAsync(string query, string language, CancellationToken token)
    {
        query = query.Trim();
        if (query.Length is < 2 or > 120) throw new ArgumentException("Enter 2–120 characters.");
        var uri = new Uri("https://geocoding-api.open-meteo.com/v1/search?name=" + Uri.EscapeDataString(query)
            + "&count=8&format=json&language=" + (language == "en" ? "en" : "ja"));
        using var json = await GetJsonAsync(uri, token);
        if (!json.RootElement.TryGetProperty("results", out var results)) return [];
        return results.EnumerateArray().Take(8).Select(result => new WeatherLocation(
            "geonames:" + result.GetProperty("id").GetInt64().ToString(CultureInfo.InvariantCulture),
            result.GetProperty("name").GetString()!, OptionalString(result, "admin1"), OptionalString(result, "country"),
            OptionalString(result, "country_code"), result.GetProperty("latitude").GetDouble(),
            result.GetProperty("longitude").GetDouble(), OptionalString(result, "timezone"), "search"))
            .Where(location => location.IsValid).ToArray();
    }

    private async Task<JsonDocument> GetJsonAsync(Uri uri, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(12));
        token = timeout.Token;
        using var response = await _client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, token);
        response.EnsureSuccessStatusCode();
        await response.Content.LoadIntoBufferAsync(1_048_576, token);
        return JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(token), new JsonDocumentOptions { MaxDepth = 16 });
    }

    private static string? OptionalString(JsonElement item, string key) =>
        item.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}
