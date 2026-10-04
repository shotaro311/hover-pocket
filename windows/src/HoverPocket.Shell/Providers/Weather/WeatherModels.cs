using System.Globalization;

namespace HoverPocket.Shell.Providers.Weather;

internal sealed record WeatherLocation(
    string Id, string Name, string? AdministrativeArea, string? Country, string? CountryCode,
    double Latitude, double Longitude, string? TimezoneIdentifier, string Source, string? LegacyRegionID = null)
{
    public static WeatherLocation Default => WeatherRegions.All.Single(region => region.Id == "13").Location;

    public bool IsValid => !string.IsNullOrWhiteSpace(Id) && Id.Length <= 160
        && Name is { Length: <= 160 } && AdministrativeArea?.Length is not > 160 && Country?.Length is not > 160
        && CountryCode?.Length is not > 2 && TimezoneIdentifier?.Length is not > 100
        && double.IsFinite(Latitude) && Latitude is >= -90 and <= 90
        && double.IsFinite(Longitude) && Longitude is >= -180 and <= 180
        && Source is "japaneseRegion" or "search" or "currentLocation";

    public string ResolveScale(string unit) => unit switch
    {
        "celsius" => "celsius",
        "fahrenheit" => "fahrenheit",
        _ => (CountryCode is null ? !RegionInfo.CurrentRegion.IsMetric
            : new[] { "BS", "BZ", "KY", "FM", "MH", "PW", "US" }.Contains(CountryCode.ToUpperInvariant()))
                ? "fahrenheit" : "celsius"
    };
}

internal sealed record WeatherRegion(string Id, string JapaneseName, string EnglishName,
    string CityJapanese, string CityEnglish, double Latitude, double Longitude)
{
    public WeatherLocation Location => new(Id, CityJapanese, JapaneseName, "日本", "JP",
        Latitude, Longitude, "Asia/Tokyo", "japaneseRegion", Id);
}

internal sealed record WeatherDay(string Date, int WeatherCode, double HighTemperature,
    double LowTemperature, int PrecipitationProbability);

internal sealed record WeatherForecast(string LocationID, string TemperatureScale, string TimezoneIdentifier,
    DateTimeOffset FetchedAt, double CurrentTemperature, int CurrentWeatherCode, WeatherDay[] Days)
{
    public bool IsValid => !string.IsNullOrWhiteSpace(TimezoneIdentifier) && double.IsFinite(CurrentTemperature)
        && Days is { Length: 8 } && Days.All(day => day is not null
            && DateOnly.TryParseExact(day.Date, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _)
            && double.IsFinite(day.HighTemperature) && double.IsFinite(day.LowTemperature)
            && day.PrecipitationProbability is >= 0 and <= 100);
}

internal sealed record WeatherState(WeatherLocation Location, string TemperatureScale,
    WeatherForecast? Forecast, bool IsStale, string? Error);
