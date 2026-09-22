using System.Net;
using System.Text.Json;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;

namespace HoverPocket.Shell.Providers.Weather;

internal static class WeatherVerifier
{
    public static async Task<int> RunAsync(Action<string> log)
    {
        var checks = 0;
        void Check(bool value, string label)
        {
            if (!value) throw new InvalidOperationException(label);
            checks++;
        }
        try
        {
            var tokyo = WeatherLocation.Default;
            Check(WeatherRegions.All.Count == 47 && WeatherRegions.All.All(region => region.Location.IsValid), "47 valid prefectures");
            Check(tokyo.Id == "13" && tokyo.ResolveScale("automatic") == "celsius", "default Tokyo / Celsius");
            var us = tokyo with { Id = "geonames:5128581", Name = "New York", CountryCode = "US", Latitude = 40.71, Longitude = -74.01, Source = "search", LegacyRegionID = null };
            Check(us.ResolveScale("automatic") == "fahrenheit" && us.ResolveScale("celsius") == "celsius", "automatic and explicit units");
            Check(!(tokyo with { Latitude = double.NaN }).IsValid && !(tokyo with { Longitude = 181 }).IsValid, "invalid coordinates rejected");
            Check(WeatherService.ForecastUri(us, "fahrenheit").Query.Contains("timezone=auto&forecast_days=8&temperature_unit=fahrenheit"), "request contract");
            var json = Fixture();
            using var document = JsonDocument.Parse(json);
            var decoded = WeatherService.Decode(document.RootElement, tokyo.Id, "celsius");
            Check(decoded.Days.Length == 8 && decoded.Days[0].Date == "2026-09-22" && decoded.CurrentTemperature == 25.5, "8-day decode");
            try
            {
                using var invalid = JsonDocument.Parse(json.Replace("25.5", "null"));
                WeatherService.Decode(invalid.RootElement, tokyo.Id, "celsius");
                throw new Exception("null temperature accepted");
            }
            catch (InvalidOperationException) { checks++; }
            var root = Path.Combine(Path.GetTempPath(), "HoverPocket", "WeatherVerify", Guid.NewGuid().ToString("N"));
            var handler = new FakeHandler(json);
            using var client = new HttpClient(handler);
            var service = new WeatherService(client);
            var store = new WeatherStore(root, service);
            var fresh = await store.LoadAsync(tokyo, "automatic", false, default);
            Check(fresh is { Forecast: not null, IsStale: false, Error: null }, "fresh forecast");
            handler.Offline = true;
            var restored = await new WeatherStore(root, service).LoadAsync(tokyo, "automatic", false, default);
            Check(restored.Forecast?.Days.Length == 8 && !restored.IsStale && handler.RequestCount == 1, "restart cache, no extra fetch");
            var stale = await store.LoadAsync(tokyo, "automatic", true, default);
            Check(stale is { Forecast: not null, IsStale: true, Error: "unavailable" }, "offline cached warning");
            var otherUnit = await store.LoadAsync(tokyo, "fahrenheit", true, default);
            Check(otherUnit.Forecast is null && otherUnit.Error == "unavailable", "unit cache separation");
            var otherLocation = await store.LoadAsync(tokyo with { Latitude = 33.59 }, "automatic", true, default);
            Check(otherLocation.Forecast is null, "coordinate cache separation");
            foreach (var file in Directory.EnumerateFiles(root, "*.json")) await File.WriteAllTextAsync(file, "{broken");
            Check((await store.LoadAsync(tokyo, "automatic", false, default)).Forecast is null, "corrupt cache fallback");
            handler.Offline = false;
            handler.Body = "{\"results\":[{\"id\":5128581,\"name\":\"New York\",\"latitude\":40.71,\"longitude\":-74.01,\"country_code\":\"US\",\"timezone\":\"America/New_York\"}]}";
            var results = await service.SearchAsync("New York", "en", default);
            Check(results.Single().Id == "geonames:5128581" && results[0].TimezoneIdentifier == "America/New_York", "worldwide location search");
            handler.Body = "{}";
            Check((await service.SearchAsync("99999", "ja", default)).Length == 0, "empty search");
            using var cancelled = new CancellationTokenSource();
            cancelled.Cancel();
            try { await store.LoadAsync(tokyo, "automatic", true, cancelled.Token); throw new Exception("cancel ignored"); }
            catch (OperationCanceledException) { checks++; }

            var savedLocation = JsonSerializer.Deserialize<WeatherLocation>(JsonSerializer.Serialize(us, BridgeJson.Options), BridgeJson.Options);
            Check(savedLocation == us, "location schema roundtrip");
            Check(PanelSizeCatalog.All.Count == 4 && PanelSizeCatalog.Get(PanelSize.ExtraLarge).Id == "extraLarge", "XL geometry");
            log($"PASS weather verify: {checks} checks (forecast, search, cache, offline, cancellation, schema, XL)");
            return 0;
        }
        catch (Exception error)
        {
            log($"FAIL weather verify after {checks} checks: {error.GetType().Name}: {error.Message}");
            return 1;
        }
    }

    private static string Fixture() => JsonSerializer.Serialize(new
    {
        timezone = "Asia/Tokyo",
        current = new { temperature_2m = 25.5, weather_code = 2 },
        daily = new
        {
            time = Enumerable.Range(0, 8).Select(day => new DateOnly(2026, 9, 22).AddDays(day).ToString("yyyy-MM-dd")).ToArray(),
            weather_code = new[] { 2, 0, 3, 61, 71, 95, 45, 80 },
            temperature_2m_max = Enumerable.Repeat(28.0, 8).ToArray(),
            temperature_2m_min = Enumerable.Repeat(20.0, 8).ToArray(),
            precipitation_probability_max = Enumerable.Repeat(30, 8).ToArray()
        }
    });

    private sealed class FakeHandler(string body) : HttpMessageHandler
    {
        public string Body { get; set; } = body;
        public bool Offline { get; set; }
        public int RequestCount { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            RequestCount++;
            if (Offline) throw new HttpRequestException("Fixture offline");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(Body) });
        }
    }
}
