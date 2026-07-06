using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace HoverPocket.Shell.Services;

internal sealed record GoogleOAuthConfiguration(
    string ClientId,
    string? ClientSecret)
{
    public static string AppDataRoot =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "HoverPocket");

    public static string ConfigurationPath => Path.Combine(AppDataRoot, "oauth.json");

    public static GoogleOAuthConfiguration? Load()
    {
        return LoadFromSources(LoadEmbedded(), ConfigurationPath);
    }

    internal static GoogleOAuthConfiguration? LoadEmbedded()
    {
        var metadata = Assembly.GetExecutingAssembly()
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .ToArray();
        return FromValues(
            ReadMetadata(metadata, "GoogleOAuthClientId"),
            ReadMetadata(metadata, "GoogleOAuthClientSecret"));
    }

    internal static GoogleOAuthConfiguration? LoadFromSources(
        GoogleOAuthConfiguration? embeddedConfiguration,
        string configurationPath)
    {
        return embeddedConfiguration ?? LoadFromJsonFile(configurationPath);
    }

    internal static GoogleOAuthConfiguration? FromValues(string? clientId, string? clientSecret)
    {
        var normalizedClientId = clientId?.Trim();
        if (string.IsNullOrWhiteSpace(normalizedClientId))
        {
            return null;
        }

        var normalizedClientSecret = clientSecret?.Trim();
        return new GoogleOAuthConfiguration(
            normalizedClientId,
            string.IsNullOrWhiteSpace(normalizedClientSecret) ? null : normalizedClientSecret);
    }

    private static GoogleOAuthConfiguration? LoadFromJsonFile(string configurationPath)
    {
        if (!File.Exists(configurationPath))
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(configurationPath));
            var root = document.RootElement;
            var container = root.TryGetProperty("installed", out var installed) ? installed : root;
            var clientId = ReadString(container, "client_id") ?? ReadString(root, "clientId");
            var clientSecret = ReadString(container, "client_secret") ?? ReadString(root, "clientSecret");
            return FromValues(clientId, clientSecret);
        }
        catch (JsonException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static string? ReadMetadata(IEnumerable<AssemblyMetadataAttribute> metadata, string key)
    {
        return metadata
            .Where(item => string.Equals(item.Key, key, StringComparison.Ordinal))
            .Select(item => item.Value)
            .FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));
    }

    private static string? ReadString(JsonElement element, string propertyName)
    {
        return element.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString()?.Trim()
            : null;
    }
}

internal sealed record GoogleOAuthToken(
    string AccessToken,
    DateTimeOffset ExpiresAt,
    IReadOnlyList<string> GrantedScopes)
{
    public bool IsFresh => ExpiresAt > DateTimeOffset.UtcNow.AddSeconds(60);
}

internal enum GoogleOAuthStoredCredentialStatus
{
    Missing,
    NeedsReconnect,
    Ready
}

internal sealed class GoogleOAuthException : Exception
{
    public GoogleOAuthException(string code, string message, bool requiresReconnect = false)
        : base(message)
    {
        Code = code;
        RequiresReconnect = requiresReconnect;
    }

    public string Code { get; }

    public bool RequiresReconnect { get; }
}

internal sealed record GoogleOAuthAuthorizationRequest(
    Uri Url,
    string State,
    string CodeVerifier,
    string CodeChallenge,
    string RedirectUri);

internal sealed class GoogleOAuthService
{
    public const string CalendarScope = "https://www.googleapis.com/auth/calendar";
    public const string CalendarEventsScope = "https://www.googleapis.com/auth/calendar.events";
    public const string CalendarReadonlyScope = "https://www.googleapis.com/auth/calendar.readonly";
    public const string CalendarListScope = "https://www.googleapis.com/auth/calendar.calendarlist";
    public const string CalendarListReadonlyScope = "https://www.googleapis.com/auth/calendar.calendarlist.readonly";

    public static readonly IReadOnlyList<string> CalendarScopes =
    [
        CalendarEventsScope,
        CalendarListReadonlyScope
    ];

    private static readonly HttpClient HttpClient = new();
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    private readonly GoogleOAuthCredentialStore _credentialStore;
    private readonly object _tokenLock = new();
    private GoogleOAuthToken? _currentToken;

    public GoogleOAuthService(GoogleOAuthCredentialStore? credentialStore = null)
    {
        _credentialStore = credentialStore ?? new GoogleOAuthCredentialStore();
    }

    public bool IsConfigured => GoogleOAuthConfiguration.Load() is not null;

    public bool HasStoredCredential() => StoredCredentialStatus() != GoogleOAuthStoredCredentialStatus.Missing;

    public bool HasRequiredCalendarCredential() => StoredCredentialStatus() == GoogleOAuthStoredCredentialStatus.Ready;

    public GoogleOAuthStoredCredentialStatus StoredCredentialStatus()
    {
        GoogleOAuthStoredCredential? credential;
        try
        {
            credential = _credentialStore.Load();
        }
        catch (InvalidOperationException)
        {
            return GoogleOAuthStoredCredentialStatus.NeedsReconnect;
        }

        if (credential is null)
        {
            return GoogleOAuthStoredCredentialStatus.Missing;
        }

        return HasRequiredCalendarScopes(credential.GrantedScopes)
            ? GoogleOAuthStoredCredentialStatus.Ready
            : GoogleOAuthStoredCredentialStatus.NeedsReconnect;
    }

    public async Task SignInAsync(CancellationToken cancellationToken = default)
    {
        var configuration = GoogleOAuthConfiguration.Load()
            ?? throw new GoogleOAuthException("missing_configuration", "Google OAuth client is not configured.");

        using var receiver = new LoopbackOAuthReceiver();
        var authorization = CreateAuthorizationRequest(configuration, receiver.RedirectUri);
        if (!OpenDefaultBrowser(authorization.Url))
        {
            throw new GoogleOAuthException("browser_open_failed", "Could not open the Google sign-in page.");
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMinutes(3));
        OAuthCallback callback;
        try
        {
            callback = await receiver.WaitForCallbackAsync(timeout.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new GoogleOAuthException("timed_out", "Google sign-in timed out.");
        }

        if (!string.IsNullOrWhiteSpace(callback.Error))
        {
            throw new GoogleOAuthException("user_denied", callback.Error);
        }

        if (!string.Equals(callback.State, authorization.State, StringComparison.Ordinal))
        {
            throw new GoogleOAuthException("state_mismatch", "Google sign-in state validation failed.");
        }

        if (string.IsNullOrWhiteSpace(callback.Code))
        {
            throw new GoogleOAuthException("missing_code", "Google did not return an authorization code.");
        }

        var response = await ExchangeAuthorizationCodeAsync(
            configuration,
            callback.Code,
            authorization.CodeVerifier,
            authorization.RedirectUri,
            cancellationToken);

        if (string.IsNullOrWhiteSpace(response.RefreshToken))
        {
            throw new GoogleOAuthException("missing_refresh_token", "Google did not return a refresh token.", requiresReconnect: true);
        }

        var scopes = ParseScopes(response.Scope);
        if (!HasRequiredCalendarScopes(scopes))
        {
            throw new GoogleOAuthException("insufficient_scopes", "Reconnect Google Calendar to allow event editing.", requiresReconnect: true);
        }

        _credentialStore.Save(new GoogleOAuthStoredCredential(response.RefreshToken, scopes));
        SetCurrentToken(new GoogleOAuthToken(
            response.AccessToken,
            DateTimeOffset.UtcNow.AddSeconds(response.ExpiresIn),
            scopes));
    }

    public void SignOut()
    {
        SetCurrentToken(null);
        _credentialStore.Delete();
    }

    public async Task<string> AccessTokenAsync(bool forceRefresh = false, CancellationToken cancellationToken = default)
    {
        _ = GoogleOAuthConfiguration.Load()
            ?? throw new GoogleOAuthException("missing_configuration", "Google OAuth client is not configured.");

        if (!forceRefresh && ReadCurrentToken() is { IsFresh: true } token)
        {
            if (!HasRequiredCalendarScopes(token.GrantedScopes))
            {
                throw new GoogleOAuthException("insufficient_scopes", "Reconnect Google Calendar to allow event editing.", requiresReconnect: true);
            }

            return token.AccessToken;
        }

        var stored = _credentialStore.Load()
            ?? throw new GoogleOAuthException("missing_refresh_token", "Google Calendar is not connected.", requiresReconnect: true);

        if (!HasRequiredCalendarScopes(stored.GrantedScopes))
        {
            throw new GoogleOAuthException("insufficient_scopes", "Reconnect Google Calendar to allow event editing.", requiresReconnect: true);
        }

        try
        {
            var response = await RefreshAccessTokenAsync(stored.RefreshToken, cancellationToken);
            var scopes = string.IsNullOrWhiteSpace(response.Scope) ? stored.GrantedScopes : ParseScopes(response.Scope);
            if (!HasRequiredCalendarScopes(scopes))
            {
                throw new GoogleOAuthException("insufficient_scopes", "Reconnect Google Calendar to allow event editing.", requiresReconnect: true);
            }

            var refreshedToken = new GoogleOAuthToken(
                response.AccessToken,
                DateTimeOffset.UtcNow.AddSeconds(response.ExpiresIn),
                scopes);
            SetCurrentToken(refreshedToken);
            return refreshedToken.AccessToken;
        }
        catch (GoogleOAuthException ex) when (ex.RequiresReconnect)
        {
            SetCurrentToken(null);
            _credentialStore.Delete();
            throw;
        }
    }

    internal static GoogleOAuthAuthorizationRequest CreateAuthorizationRequest(
        GoogleOAuthConfiguration configuration,
        string redirectUri)
    {
        var state = RandomBase64Url(32);
        var verifier = RandomBase64Url(64);
        var challenge = CodeChallenge(verifier);
        var query = PercentEncodedForm(new Dictionary<string, string>
        {
            ["client_id"] = configuration.ClientId,
            ["redirect_uri"] = redirectUri,
            ["response_type"] = "code",
            ["scope"] = string.Join(' ', CalendarScopes),
            ["access_type"] = "offline",
            ["prompt"] = "consent",
            ["state"] = state,
            ["code_challenge"] = challenge,
            ["code_challenge_method"] = "S256"
        });
        return new GoogleOAuthAuthorizationRequest(
            new Uri($"https://accounts.google.com/o/oauth2/v2/auth?{query}"),
            state,
            verifier,
            challenge,
            redirectUri);
    }

    internal static bool HasRequiredCalendarScopes(IEnumerable<string> scopes)
    {
        var granted = scopes.ToHashSet(StringComparer.Ordinal);
        return HasCalendarEventsScope(granted) && HasCalendarListScope(granted);
    }

    private static bool HasCalendarEventsScope(ISet<string> granted)
    {
        return granted.Contains(CalendarEventsScope) || granted.Contains(CalendarScope);
    }

    private static bool HasCalendarListScope(ISet<string> granted)
    {
        return granted.Contains(CalendarListReadonlyScope)
            || granted.Contains(CalendarListScope)
            || granted.Contains(CalendarReadonlyScope)
            || granted.Contains(CalendarScope);
    }

    internal static string CodeChallenge(string verifier)
    {
        return Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
    }

    private async Task<GoogleOAuthTokenResponse> ExchangeAuthorizationCodeAsync(
        GoogleOAuthConfiguration configuration,
        string code,
        string verifier,
        string redirectUri,
        CancellationToken cancellationToken)
    {
        var form = new Dictionary<string, string>
        {
            ["client_id"] = configuration.ClientId,
            ["code"] = code,
            ["code_verifier"] = verifier,
            ["grant_type"] = "authorization_code",
            ["redirect_uri"] = redirectUri
        };
        if (!string.IsNullOrWhiteSpace(configuration.ClientSecret))
        {
            form["client_secret"] = configuration.ClientSecret;
        }

        return await PostTokenRequestAsync(form, cancellationToken);
    }

    private async Task<GoogleOAuthTokenResponse> RefreshAccessTokenAsync(
        string refreshToken,
        CancellationToken cancellationToken)
    {
        var configuration = GoogleOAuthConfiguration.Load()
            ?? throw new GoogleOAuthException("missing_configuration", "Google OAuth client is not configured.");
        var form = new Dictionary<string, string>
        {
            ["client_id"] = configuration.ClientId,
            ["grant_type"] = "refresh_token",
            ["refresh_token"] = refreshToken
        };
        if (!string.IsNullOrWhiteSpace(configuration.ClientSecret))
        {
            form["client_secret"] = configuration.ClientSecret;
        }

        return await PostTokenRequestAsync(form, cancellationToken, treatsStoredCredentialFailureAsReconnect: true);
    }

    private static async Task<GoogleOAuthTokenResponse> PostTokenRequestAsync(
        Dictionary<string, string> form,
        CancellationToken cancellationToken,
        bool treatsStoredCredentialFailureAsReconnect = false)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://oauth2.googleapis.com/token");
        request.Content = new StringContent(PercentEncodedForm(form), Encoding.UTF8, "application/x-www-form-urlencoded");
        using var response = await HttpClient.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var error = TryDeserialize<GoogleOAuthErrorResponse>(body);
            if (treatsStoredCredentialFailureAsReconnect && error?.RequiresReconnect == true)
            {
                throw new GoogleOAuthException("stored_credential_requires_reconnect", "Reconnect Google Calendar to continue.", requiresReconnect: true);
            }

            throw new GoogleOAuthException("token_endpoint_failed", error?.SafeDescription ?? "Google token request failed.");
        }

        var token = TryDeserialize<GoogleOAuthTokenResponse>(body);
        return token ?? throw new GoogleOAuthException("token_decode_failed", "Google token response could not be read.");
    }

    private static T? TryDeserialize<T>(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<T>(json, JsonOptions);
        }
        catch (JsonException)
        {
            return default;
        }
    }

    private static bool OpenDefaultBrowser(Uri url)
    {
        try
        {
            using var _ = Process.Start(new ProcessStartInfo(url.ToString())
            {
                UseShellExecute = true
            });
            return true;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    private GoogleOAuthToken? ReadCurrentToken()
    {
        lock (_tokenLock)
        {
            return _currentToken;
        }
    }

    private void SetCurrentToken(GoogleOAuthToken? token)
    {
        lock (_tokenLock)
        {
            _currentToken = token;
        }
    }

    private static IReadOnlyList<string> ParseScopes(string? scope)
    {
        return string.IsNullOrWhiteSpace(scope)
            ? CalendarScopes
            : scope.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    }

    private static string RandomBase64Url(int byteCount)
    {
        var bytes = new byte[byteCount];
        RandomNumberGenerator.Fill(bytes);
        return Base64Url(bytes);
    }

    private static string Base64Url(byte[] bytes)
    {
        return Convert.ToBase64String(bytes)
            .Replace("+", "-", StringComparison.Ordinal)
            .Replace("/", "_", StringComparison.Ordinal)
            .Replace("=", string.Empty, StringComparison.Ordinal);
    }

    private static string PercentEncodedForm(Dictionary<string, string> values)
    {
        return string.Join('&', values
            .OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => $"{Escape(pair.Key)}={Escape(pair.Value)}"));
    }

    private static string Escape(string value)
    {
        return Uri.EscapeDataString(value).Replace("%20", "+", StringComparison.Ordinal);
    }

    private sealed record GoogleOAuthTokenResponse(
        [property: JsonPropertyName("access_token")] string AccessToken,
        [property: JsonPropertyName("expires_in")] int ExpiresIn,
        [property: JsonPropertyName("refresh_token")] string? RefreshToken,
        [property: JsonPropertyName("scope")] string? Scope);

    private sealed record GoogleOAuthErrorResponse(
        [property: JsonPropertyName("error")] string? Error,
        [property: JsonPropertyName("error_description")] string? ErrorDescription)
    {
        public bool RequiresReconnect => Error is "invalid_grant" or "invalid_scope";

        public string SafeDescription => ErrorDescription ?? Error ?? "Google authorization failed.";
    }
}
