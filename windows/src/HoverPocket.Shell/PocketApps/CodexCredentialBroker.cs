using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;

namespace HoverPocket.Shell.PocketApps;

internal sealed class CodexCredentialBrokerException : Exception
{
    public CodexCredentialBrokerException() : base("Credential unavailable.")
    {
    }
}

internal sealed class CodexCredentialBrokerLease
{
    private readonly object _gate = new();
    private readonly string _expectedCapability;
    private readonly DateTimeOffset _expiresAt;
    private readonly Func<string> _secretProvider;
    private bool _consumed;

    public CodexCredentialBrokerLease(
        TimeSpan lifetime,
        Func<string> secretProvider)
        : this(CreateCapability(), DateTimeOffset.UtcNow.Add(lifetime), secretProvider)
    {
        if (lifetime <= TimeSpan.Zero || lifetime > TimeSpan.FromSeconds(60))
        {
            throw new CodexCredentialBrokerException();
        }
    }

    internal CodexCredentialBrokerLease(
        string capability,
        DateTimeOffset expiresAt,
        Func<string> secretProvider)
    {
        if (!IsValidCapability(capability))
        {
            throw new CodexCredentialBrokerException();
        }
        Capability = capability;
        _expectedCapability = capability;
        _expiresAt = expiresAt;
        _secretProvider = secretProvider ?? throw new CodexCredentialBrokerException();
    }

    public string Capability { get; }

    public bool IsConsumed
    {
        get
        {
            lock (_gate)
            {
                return _consumed;
            }
        }
    }

    public string Redeem(string presentedCapability, DateTimeOffset? now = null)
    {
        lock (_gate)
        {
            if (_consumed)
            {
                throw new CodexCredentialBrokerException();
            }
            _consumed = true;
            if ((now ?? DateTimeOffset.UtcNow) > _expiresAt
                || !FixedTimeEqual(presentedCapability, _expectedCapability))
            {
                throw new CodexCredentialBrokerException();
            }
        }

        var secret = _secretProvider();
        if (!IsValidSecret(secret))
        {
            throw new CodexCredentialBrokerException();
        }
        return secret;
    }

    public void Cancel()
    {
        lock (_gate)
        {
            _consumed = true;
        }
    }

    internal static bool IsValidSecret(string? value) =>
        !string.IsNullOrEmpty(value)
        && Encoding.UTF8.GetByteCount(value) <= 8_192
        && !value.Any(char.IsControl);

    private static string CreateCapability()
    {
        var value = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
        return value.TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    private static bool IsValidCapability(string? value) =>
        value is not null
        && value.Length is >= 32 and <= 128
        && value.All(character =>
            character is >= '0' and <= '9'
            or >= 'A' and <= 'Z'
            or >= 'a' and <= 'z'
            or '-' or '_');

    private static bool FixedTimeEqual(string? left, string right)
    {
        var leftBytes = Encoding.UTF8.GetBytes(left ?? string.Empty);
        var rightBytes = Encoding.UTF8.GetBytes(right);
        var length = Math.Max(leftBytes.Length, rightBytes.Length);
        var leftPadded = new byte[length];
        var rightPadded = new byte[length];
        leftBytes.CopyTo(leftPadded, 0);
        rightBytes.CopyTo(rightPadded, 0);
        return CryptographicOperations.FixedTimeEquals(leftPadded, rightPadded)
            && leftBytes.Length == rightBytes.Length;
    }
}

internal sealed class CodexCredentialBrokerServer : IDisposable
{
    private const string RequestPrefix = "HP-CODEX-BROKER/1 ";
    private readonly CodexCredentialBrokerLease _lease;
    private readonly NamedPipeServerStream _pipe;
    private readonly CancellationTokenSource _lifetimeCancellation = new();
    private int _disposed;

    public CodexCredentialBrokerServer(
        TimeSpan lifetime,
        Func<string> secretProvider)
    {
        if (lifetime <= TimeSpan.Zero || lifetime > TimeSpan.FromSeconds(60))
        {
            throw new CodexCredentialBrokerException();
        }
        _lease = new CodexCredentialBrokerLease(lifetime, secretProvider);
        PipeName = $"hoverpocket-codex-broker-{Guid.NewGuid():N}";
        _pipe = new NamedPipeServerStream(
            PipeName,
            PipeDirection.InOut,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly,
            4_096,
            12_000);
        _lifetimeCancellation.CancelAfter(lifetime);
        Completion = ServeAsync();
    }

    public string PipeName { get; }
    public string Capability => _lease.Capability;
    public Task Completion { get; }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }
        _lease.Cancel();
        _lifetimeCancellation.Cancel();
        _pipe.Dispose();
        _lifetimeCancellation.Dispose();
    }

    private async Task ServeAsync()
    {
        try
        {
            await _pipe.WaitForConnectionAsync(_lifetimeCancellation.Token).ConfigureAwait(false);
            using var requestCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                _lifetimeCancellation.Token);
            requestCancellation.CancelAfter(TimeSpan.FromSeconds(2));
            var request = await ReadLineAsync(_pipe, 512, requestCancellation.Token).ConfigureAwait(false);
            if (request is null || !request.StartsWith(RequestPrefix, StringComparison.Ordinal))
            {
                _lease.Cancel();
                await WriteLineAsync(_pipe, "ERR", requestCancellation.Token).ConfigureAwait(false);
                return;
            }

            try
            {
                var capability = request[RequestPrefix.Length..];
                var secret = _lease.Redeem(capability);
                var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(secret));
                await WriteLineAsync(_pipe, $"OK {encoded}", requestCancellation.Token).ConfigureAwait(false);
            }
            catch
            {
                await WriteLineAsync(_pipe, "ERR", requestCancellation.Token).ConfigureAwait(false);
            }
        }
        catch
        {
        }
        finally
        {
            _lease.Cancel();
            _pipe.Dispose();
        }
    }

    internal static async Task<string?> ReadLineAsync(
        Stream stream,
        int maximumBytes,
        CancellationToken cancellationToken)
    {
        var bytes = new List<byte>(Math.Min(maximumBytes, 512));
        var buffer = new byte[1];
        while (bytes.Count < maximumBytes)
        {
            var count = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (count != 1)
            {
                return null;
            }
            if (buffer[0] == (byte)'\n')
            {
                return Encoding.UTF8.GetString(bytes.ToArray());
            }
            if (buffer[0] is 0 or (byte)'\r')
            {
                return null;
            }
            bytes.Add(buffer[0]);
        }
        return null;
    }

    internal static async Task WriteLineAsync(
        Stream stream,
        string value,
        CancellationToken cancellationToken)
    {
        var bytes = Encoding.UTF8.GetBytes(value + "\n");
        await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }
}

internal static class CodexCredentialBrokerClient
{
    public static async Task<string> FetchSecretAsync(
        string pipeName,
        string capability,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        if (!pipeName.StartsWith("hoverpocket-codex-broker-", StringComparison.Ordinal)
            || pipeName.Length > 96
            || capability.Length > 128)
        {
            throw new CodexCredentialBrokerException();
        }

        using var timeoutCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCancellation.CancelAfter(timeout ?? TimeSpan.FromSeconds(2));
        await using var pipe = new NamedPipeClientStream(
            ".",
            pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous);
        try
        {
            await pipe.ConnectAsync(timeoutCancellation.Token).ConfigureAwait(false);
            await CodexCredentialBrokerServer.WriteLineAsync(
                pipe,
                $"HP-CODEX-BROKER/1 {capability}",
                timeoutCancellation.Token).ConfigureAwait(false);
            var response = await CodexCredentialBrokerServer.ReadLineAsync(
                pipe,
                12_000,
                timeoutCancellation.Token).ConfigureAwait(false);
            if (response is null || !response.StartsWith("OK ", StringComparison.Ordinal))
            {
                throw new CodexCredentialBrokerException();
            }
            var bytes = Convert.FromBase64String(response[3..]);
            var secret = Encoding.UTF8.GetString(bytes);
            if (!CodexCredentialBrokerLease.IsValidSecret(secret))
            {
                throw new CodexCredentialBrokerException();
            }
            return secret;
        }
        catch (CodexCredentialBrokerException)
        {
            throw;
        }
        catch
        {
            throw new CodexCredentialBrokerException();
        }
    }
}

internal static class CodexCredentialBrokerHelper
{
    public const string Argument = "--codex-credential-helper";
    public const string EndpointEnvironmentKey = "HOVERPOCKET_CODEX_BROKER_ENDPOINT";
    public const string CapabilityEnvironmentKey = "HOVERPOCKET_CODEX_BROKER_CAPABILITY";

    public static int Run() => RunAsync(
        Environment.GetEnvironmentVariable(EndpointEnvironmentKey),
        Environment.GetEnvironmentVariable(CapabilityEnvironmentKey),
        Console.Out,
        Console.Error,
        CancellationToken.None).GetAwaiter().GetResult();

    internal static async Task<int> RunAsync(
        string? pipeName,
        string? capability,
        TextWriter standardOutput,
        TextWriter standardError,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(pipeName) || string.IsNullOrWhiteSpace(capability))
        {
            return 1;
        }
        try
        {
            var secret = await CodexCredentialBrokerClient.FetchSecretAsync(
                pipeName,
                capability,
                cancellationToken: cancellationToken).ConfigureAwait(false);
            await standardOutput.WriteAsync(secret).ConfigureAwait(false);
            await standardOutput.FlushAsync().ConfigureAwait(false);
            return 0;
        }
        catch
        {
            await standardError.WriteLineAsync("credential unavailable").ConfigureAwait(false);
            await standardError.FlushAsync().ConfigureAwait(false);
            return 1;
        }
    }
}
