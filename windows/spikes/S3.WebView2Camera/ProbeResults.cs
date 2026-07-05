namespace S3.WebView2Camera;

public sealed record PageReadyInfo(bool SecureContext, bool HasMediaDevices, string Href);

public sealed record CameraProbeResult(string Status, string? Detail, string? Extra);
