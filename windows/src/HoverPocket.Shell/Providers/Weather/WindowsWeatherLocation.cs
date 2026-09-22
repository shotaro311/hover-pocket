using System.Globalization;
using Windows.Devices.Geolocation;

namespace HoverPocket.Shell.Providers.Weather;

internal static class WindowsWeatherLocation
{
    // Called only by the Settings button, on the foreground window's UI thread.
    public static async Task<WeatherLocation> GetAsync(CancellationToken token)
    {
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
            timeout.CancelAfter(TimeSpan.FromSeconds(20));
            var access = await Geolocator.RequestAccessAsync().AsTask(timeout.Token);
            if (access != GeolocationAccessStatus.Allowed)
                throw new UnauthorizedAccessException();
            var locator = new Geolocator { DesiredAccuracy = PositionAccuracy.Default };
            var position = await locator.GetGeopositionAsync(TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(15))
                .AsTask(timeout.Token);
            var coordinate = position.Coordinate.Point.Position;
            return new WeatherLocation(
                "current:" + Math.Round(coordinate.Latitude, 2).ToString("F2", CultureInfo.InvariantCulture)
                + "," + Math.Round(coordinate.Longitude, 2).ToString("F2", CultureInfo.InvariantCulture),
                "", null, null, null, Math.Round(coordinate.Latitude, 5), Math.Round(coordinate.Longitude, 5),
                null, "currentLocation");
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
        catch (Exception error) when (error is UnauthorizedAccessException or OperationCanceledException
            or System.Runtime.InteropServices.COMException)
        {
            throw new InvalidOperationException("Location unavailable. Select a city or prefecture instead.");
        }
    }
}
