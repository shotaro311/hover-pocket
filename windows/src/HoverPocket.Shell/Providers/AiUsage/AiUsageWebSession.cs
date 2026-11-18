using System.Text.Json;
using System.Windows.Interop;
using Microsoft.Web.WebView2.Core;

namespace HoverPocket.Shell.Providers.AiUsage;

internal sealed record AiUsageFetchResponse(int Status, string Type, string Url, string Body, bool Truncated);

/// <summary>
/// A hidden, non-activating WebView2 that runs <c>fetch()</c> inside one service's own origin. Each
/// service has its own WebView2 profile, so signing out of one never touches another. The view has no
/// bridge, no host objects and no popups; top-level navigation is limited to the one origin it was sent
/// to, and every request is a same-origin fetch whose body is read with a size cap.
/// </summary>
internal sealed class AiUsageWebSession : IAsyncDisposable
{
    private const int WsPopup = unchecked((int)0x80000000);
    private const int WsExToolWindow = 0x00000080;
    private const int WsExNoActivate = 0x08000000;

    private static readonly Dictionary<string, Task<CoreWebView2Environment>> Environments = new(StringComparer.OrdinalIgnoreCase);

    private readonly HwndSource _host;
    private readonly CoreWebView2Controller _controller;
    private string? _allowedOrigin;
    private bool _disposed;

    private AiUsageWebSession(HwndSource host, CoreWebView2Controller controller)
    {
        _host = host;
        _controller = controller;
        controller.CoreWebView2.NavigationStarting += (_, args) =>
        {
            if (_allowedOrigin is null || OriginOf(args.Uri) != _allowedOrigin) args.Cancel = true;
        };
        controller.CoreWebView2.NewWindowRequested += (_, args) => args.Handled = true;
    }

    public CoreWebView2 CoreWebView2 => _controller.CoreWebView2;

    /// <summary>Shared by the hidden fetcher and the visible sign-in window so both see the same profiles.</summary>
    public static Task<CoreWebView2Environment> GetEnvironmentAsync(string userDataFolder)
    {
        var folder = Path.GetFullPath(userDataFolder);
        lock (Environments)
        {
            if (!Environments.TryGetValue(folder, out var environment) || environment.IsFaulted || environment.IsCanceled)
            {
                Directory.CreateDirectory(folder);
                environment = CoreWebView2Environment.CreateAsync(null, folder);
                Environments[folder] = environment;
            }
            return environment;
        }
    }

    public static CoreWebView2ControllerOptions ProfileOptions(CoreWebView2Environment environment, string service)
    {
        var options = environment.CreateCoreWebView2ControllerOptions();
        options.ProfileName = "ai-usage-" + service;
        options.IsInPrivateModeEnabled = false;
        return options;
    }

    /// <summary>Must be called on a WPF dispatcher thread.</summary>
    public static async Task<AiUsageWebSession> CreateAsync(string userDataFolder, string service)
    {
        var environment = await GetEnvironmentAsync(userDataFolder);
        var host = new HwndSource(new HwndSourceParameters("HoverPocketAiUsage")
        {
            Width = 1,
            Height = 1,
            PositionX = -32000,
            PositionY = -32000,
            WindowStyle = WsPopup,
            ExtendedWindowStyle = WsExToolWindow | WsExNoActivate
        });
        try
        {
            var controller = await environment.CreateCoreWebView2ControllerAsync(host.Handle, ProfileOptions(environment, service));
            controller.IsVisible = false;
            var settings = controller.CoreWebView2.Settings;
            settings.AreDevToolsEnabled = false;
            settings.AreDefaultContextMenusEnabled = false;
            settings.AreHostObjectsAllowed = false;
            settings.IsWebMessageEnabled = false;
            settings.IsStatusBarEnabled = false;
            settings.AreDefaultScriptDialogsEnabled = false;
            settings.IsGeneralAutofillEnabled = false;
            settings.IsPasswordAutosaveEnabled = false;
            controller.CoreWebView2.IsMuted = true;
            return new AiUsageWebSession(host, controller);
        }
        catch
        {
            host.Dispose();
            throw;
        }
    }

    /// <summary>Opens <paramref name="uri"/> and confirms the document now belongs to exactly that origin.</summary>
    public async Task NavigateAsync(Uri uri, TimeSpan timeout, CancellationToken cancellationToken)
    {
        _allowedOrigin = OriginOf(uri.AbsoluteUri);
        var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void OnCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs args) => completed.TrySetResult();
        CoreWebView2.NavigationCompleted += OnCompleted;
        try
        {
            CoreWebView2.Navigate(uri.AbsoluteUri);
            await completed.Task.WaitAsync(timeout, cancellationToken);
        }
        finally
        {
            CoreWebView2.NavigationCompleted -= OnCompleted;
        }
        if (OriginOf(CoreWebView2.Source) != _allowedOrigin)
            throw new AiUsageFetchException(AiUsageErrorCodes.Network);
    }

    /// <summary>
    /// Runs one same-origin fetch in the current page. The body is streamed and cut at
    /// <paramref name="maxChars"/>; <see cref="AiUsageFetchResponse.Truncated"/> reports the cut.
    /// </summary>
    public async Task<AiUsageFetchResponse> FetchAsync(
        string path,
        string method,
        IReadOnlyDictionary<string, string>? headers,
        string? body,
        string redirect,
        int maxChars,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        if (!path.StartsWith('/') || path.StartsWith("//", StringComparison.Ordinal))
            throw new ArgumentException("path must be origin-relative", nameof(path));
        var arguments = JsonSerializer.Serialize(new
        {
            origin = _allowedOrigin,
            path,
            method,
            headers = headers ?? new Dictionary<string, string>(),
            body,
            redirect,
            maxChars
        });
        // Every helper is declared inside the function: a top-level `const` would survive in the page and
        // make the next evaluation in the same document fail with a redeclaration error.
        var expression = """
            (async (a) => {
            """ + ReadCappedScript + """
              if (location.origin !== a.origin) throw new Error("origin");
              const options = { method: a.method, credentials: "include", mode: "same-origin", headers: a.headers, redirect: a.redirect, cache: "no-store" };
              if (a.body !== null) options.body = a.body;
              const r = await fetch(a.path, options);
              const read = r.type === "opaqueredirect" ? { text: "", truncated: false } : await readCapped(r, a.maxChars);
              return JSON.stringify({ status: r.status, type: r.type, url: r.url, body: read.text, truncated: read.truncated });
            })
            """ + "(" + arguments + ")";
        var json = await EvaluateAsync(expression, timeout, cancellationToken);
        try
        {
            var response = JsonSerializer.Deserialize<AiUsageFetchResponse>(json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            return response ?? throw new AiUsageFetchException(AiUsageErrorCodes.Network);
        }
        catch (JsonException)
        {
            throw new AiUsageFetchException(AiUsageErrorCodes.Network);
        }
    }

    /// <summary>
    /// Declares <c>readCapped(response, maxChars)</c>, which reads a body as text and stops once it
    /// exceeds the cap (counted in UTF-16 characters). Insert it inside a function body, never at the top
    /// level of an evaluated script.
    /// </summary>
    internal const string ReadCappedScript = """
        const readCapped = async (r, max) => {
          if (!r.body) return { text: "", truncated: false };
          const reader = r.body.getReader();
          const decoder = new TextDecoder();
          let text = "";
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            text += decoder.decode(value, { stream: true });
            if (text.length > max) { await reader.cancel(); return { text: text.slice(0, max), truncated: true }; }
          }
          return { text: text + decoder.decode(), truncated: false };
        };
        """;

    /// <summary>
    /// Evaluates a script that resolves to a string. DevTools <c>Runtime.evaluate</c> is used because
    /// <c>ExecuteScriptAsync</c> does not await promises. Only fixed scripts and JSON-encoded arguments
    /// are evaluated; response text from the sites is never part of the expression.
    /// </summary>
    public async Task<string> EvaluateAsync(string expression, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var parameters = JsonSerializer.Serialize(new { expression, awaitPromise = true, returnByValue = true, userGesture = false });
        var raw = await CoreWebView2.CallDevToolsProtocolMethodAsync("Runtime.evaluate", parameters).WaitAsync(timeout, cancellationToken);
        using var document = JsonDocument.Parse(raw);
        var root = document.RootElement;
        if (root.TryGetProperty("exceptionDetails", out _))
            throw new AiUsageFetchException(AiUsageErrorCodes.Network);
        if (root.TryGetProperty("result", out var result) && result.TryGetProperty("value", out var value)
            && value.ValueKind == JsonValueKind.String)
            return value.GetString() ?? string.Empty;
        throw new AiUsageFetchException(AiUsageErrorCodes.Network);
    }

    /// <summary>Removes cookies, storage and cache of this service's profile only.</summary>
    public Task ClearProfileAsync() => CoreWebView2.Profile.ClearBrowsingDataAsync();

    internal static string? OriginOf(string? uri) =>
        Uri.TryCreate(uri, UriKind.Absolute, out var parsed) && parsed.Scheme == Uri.UriSchemeHttps
            ? parsed.GetLeftPart(UriPartial.Authority).ToLowerInvariant()
            : null;

    public ValueTask DisposeAsync()
    {
        if (_disposed) return ValueTask.CompletedTask;
        _disposed = true;
        try { _controller.Close(); }
        catch (Exception exception) when (exception is InvalidOperationException or System.Runtime.InteropServices.COMException) { }
        _host.Dispose();
        return ValueTask.CompletedTask;
    }
}

internal sealed class AiUsageFetchException(string code) : Exception(code)
{
    public string Code { get; } = code;
}
