using System.Net;
using System.Net.Sockets;
using System.Text;

namespace HoverPocket.Shell.Services;

internal sealed record OAuthCallback(
    string? Code,
    string? State,
    string? Error);

internal sealed class LoopbackOAuthReceiver : IDisposable
{
    private readonly TcpListener _listener;
    private bool _disposed;

    public LoopbackOAuthReceiver()
    {
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start();
        var endpoint = (IPEndPoint)_listener.LocalEndpoint;
        RedirectUri = $"http://127.0.0.1:{endpoint.Port}/";
    }

    public string RedirectUri { get; }

    public async Task<OAuthCallback> WaitForCallbackAsync(CancellationToken cancellationToken)
    {
        using var client = await _listener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
        using var stream = client.GetStream();
        using var reader = new StreamReader(stream, Encoding.ASCII, detectEncodingFromByteOrderMarks: false, leaveOpen: true);

        var requestLine = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false) ?? string.Empty;
        while (!string.IsNullOrEmpty(await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false)))
        {
        }

        var callback = ParseRequestLine(requestLine);
        var success = string.IsNullOrWhiteSpace(callback.Error) && !string.IsNullOrWhiteSpace(callback.Code);
        var body = success
            ? "<!doctype html><html><body><h1>Google Calendar connected</h1><p>You can close this tab.</p></body></html>"
            : "<!doctype html><html><body><h1>Google Calendar sign-in failed</h1><p>Return to HoverPocket and try again.</p></body></html>";
        var response = Encoding.UTF8.GetBytes(
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            $"Content-Length: {Encoding.UTF8.GetByteCount(body)}\r\n" +
            "Connection: close\r\n\r\n" +
            body);
        await stream.WriteAsync(response, cancellationToken).ConfigureAwait(false);
        return callback;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _listener.Stop();
    }

    private static OAuthCallback ParseRequestLine(string requestLine)
    {
        var parts = requestLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2 || !parts[0].Equals("GET", StringComparison.OrdinalIgnoreCase))
        {
            return new OAuthCallback(null, null, "invalid_request");
        }

        var target = parts[1];
        var queryStart = target.IndexOf('?', StringComparison.Ordinal);
        if (queryStart < 0 || queryStart == target.Length - 1)
        {
            return new OAuthCallback(null, null, "missing_query");
        }

        var query = ParseQuery(target[(queryStart + 1)..]);
        query.TryGetValue("code", out var code);
        query.TryGetValue("state", out var state);
        query.TryGetValue("error", out var error);
        return new OAuthCallback(code, state, error);
    }

    private static Dictionary<string, string> ParseQuery(string query)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = part.IndexOf('=', StringComparison.Ordinal);
            var key = separator < 0 ? part : part[..separator];
            var value = separator < 0 ? string.Empty : part[(separator + 1)..];
            values[Decode(key)] = Decode(value);
        }

        return values;
    }

    private static string Decode(string value)
    {
        return Uri.UnescapeDataString(value.Replace("+", " ", StringComparison.Ordinal));
    }
}
