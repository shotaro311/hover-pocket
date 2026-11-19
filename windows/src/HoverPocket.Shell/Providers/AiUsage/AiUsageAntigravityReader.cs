using System.Net;
using System.Net.Http;
using System.Net.Sockets;

namespace HoverPocket.Shell.Providers.AiUsage;

/// <summary>
/// Reads the Antigravity CLI (agy) limits from the Gemini Peer running on this PC
/// (codex-peer-gemini-windows, docs/gemini-usage.md). <c>GET /history/api/usage</c> returns the peer's
/// saved reading; when it is stale or the user pressed refresh, <c>POST /history/api/usage/refresh</c>
/// has the peer run agy's built-in <c>/usage</c> (no model request, so no quota is used). The peer
/// coalesces refreshes and allows one per 30 seconds, and compares <c>Host</c> and <c>Origin</c> exactly,
/// so the literal loopback address is used. Nothing leaves this PC.
/// </summary>
internal sealed class AiUsageAntigravityReader : IDisposable
{
    /// <summary>The Gemini Peer's default listen address (<c>listen.port</c> 17848 in its config).</summary>
    public static readonly Uri DefaultBaseAddress = new("http://127.0.0.1:17848");
    private const string UsagePath = "/history/api/usage";
    private const string RefreshPath = "/history/api/usage/refresh";
    private const int MaxBodyBytes = 256 * 1024;
    private static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(5);
    // The peer stops its agy capture after 25 seconds; this leaves room for agy's start-up.
    private static readonly TimeSpan RefreshTimeout = TimeSpan.FromSeconds(40);

    private readonly HttpClient _http;
    private readonly Uri _baseAddress;
    private readonly Func<DateTimeOffset> _clock;

    public AiUsageAntigravityReader(Uri? baseAddress = null, HttpMessageHandler? handler = null, Func<DateTimeOffset>? clock = null)
    {
        _baseAddress = baseAddress ?? DefaultBaseAddress;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _http = new HttpClient(handler ?? new SocketsHttpHandler
        {
            UseProxy = false,
            UseCookies = false,
            AllowAutoRedirect = false,
            ConnectTimeout = TimeSpan.FromSeconds(3)
        })
        {
            Timeout = Timeout.InfiniteTimeSpan
        };
    }

    /// <summary>
    /// Reads the saved reading and renews it when it is not fresh or <paramref name="force"/> is set. If
    /// the renewal fails, the saved values are still returned, marked stale with this attempt's reason,
    /// so a failed refresh never reads as "updated".
    /// </summary>
    public async Task<AiUsageResult> ReadAsync(bool force, CancellationToken cancellationToken)
    {
        var (saved, answered) = await SendAsync(HttpMethod.Get, UsagePath, ReadTimeout, cancellationToken);
        // Only a peer that answered 200 is asked to renew; one that is down, refusing or hung is not waited on twice.
        if (!answered) return saved;
        if (!force && saved.Status == AiUsageStatus.Ok) return saved;

        var (renewed, _) = await SendAsync(HttpMethod.Post, RefreshPath, RefreshTimeout, cancellationToken);
        if (renewed.Status == AiUsageStatus.Ok || renewed.Reading is not null) return renewed;
        if (saved.Reading is { } reading) return AiUsageResult.StaleReading(reading, renewed.ErrorCode ?? AiUsageErrorCodes.Unavailable);
        return renewed;
    }

    /// <summary>Returns the parsed result and whether the peer answered 200 (only then is a renewal worth asking for).</summary>
    private async Task<(AiUsageResult Result, bool Answered)> SendAsync(HttpMethod method, string path, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        using var request = new HttpRequestMessage(method, new Uri(_baseAddress, path));
        request.Headers.Accept.ParseAdd("application/json");
        if (method == HttpMethod.Post)
        {
            // The peer accepts a refresh only from its own origin.
            request.Headers.TryAddWithoutValidation("Origin", _baseAddress.GetLeftPart(UriPartial.Authority));
            request.Content = new ByteArrayContent([]);
        }
        try
        {
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            // 403/404/405: the peer's interface or its address checks changed; 5xx and the rest: try later.
            if (response.StatusCode is HttpStatusCode.Forbidden or HttpStatusCode.NotFound or HttpStatusCode.MethodNotAllowed)
                return (AiUsageResult.Failure(AiUsageErrorCodes.Changed), false);
            if (response.StatusCode != HttpStatusCode.OK) return (AiUsageResult.Failure(AiUsageErrorCodes.Unavailable), false);
            var body = await ReadCappedAsync(response.Content, deadline.Token);
            if (body is null) return (AiUsageResult.Failure(AiUsageErrorCodes.Changed), true);
            try
            {
                return (AiUsageParsers.ParseAntigravity(body, _clock()), true);
            }
            catch (AiUsageParseException)
            {
                return (AiUsageResult.Failure(AiUsageErrorCodes.Changed), true);
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return (AiUsageResult.Failure(AiUsageErrorCodes.Timeout), false);
        }
        catch (HttpRequestException exception) when (exception.InnerException is SocketException { SocketErrorCode: SocketError.ConnectionRefused })
        {
            // Nothing listens on the peer's port: it is not running.
            return (AiUsageResult.Failure(AiUsageErrorCodes.PeerMissing), false);
        }
        catch (HttpRequestException)
        {
            return (AiUsageResult.Failure(AiUsageErrorCodes.Network), false);
        }
        catch (IOException)
        {
            // The connection ended while the body was arriving (HttpIOException and the like).
            return (AiUsageResult.Failure(AiUsageErrorCodes.Network), false);
        }
    }

    /// <summary>Reads the body up to <see cref="MaxBodyBytes"/>; <c>null</c> when it is larger.</summary>
    private static async Task<string?> ReadCappedAsync(HttpContent content, CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength is > MaxBodyBytes) return null;
        await using var stream = await content.ReadAsStreamAsync(cancellationToken);
        var buffer = new byte[MaxBodyBytes + 1];
        var length = 0;
        int read;
        while (length < buffer.Length && (read = await stream.ReadAsync(buffer.AsMemory(length), cancellationToken)) > 0) length += read;
        return length > MaxBodyBytes ? null : System.Text.Encoding.UTF8.GetString(buffer, 0, length);
    }

    public void Dispose() => _http.Dispose();
}
