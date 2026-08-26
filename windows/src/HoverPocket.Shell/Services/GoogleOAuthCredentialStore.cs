using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HoverPocket.Shell.Configuration;

namespace HoverPocket.Shell.Services;

internal sealed record GoogleOAuthStoredCredential(
    string RefreshToken,
    IReadOnlyList<string> GrantedScopes);

internal sealed class GoogleOAuthCredentialStore
{
    private const uint CredentialTypeGeneric = 1;
    private const uint CredentialPersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;
    private const string DefaultTargetName = "HoverPocket.GoogleOAuth.RefreshToken";
    private const string DefaultAccountName = "default";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    private readonly string _targetName;

    public GoogleOAuthCredentialStore(string targetName = DefaultTargetName)
    {
        _targetName = targetName;
    }

    public GoogleOAuthStoredCredential? Load()
    {
        if (!CredReadW(_targetName, CredentialTypeGeneric, 0, out var credentialPointer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == ErrorNotFound)
            {
                return null;
            }

            throw new InvalidOperationException($"Credential Manager read failed: {error}");
        }

        try
        {
            var credential = Marshal.PtrToStructure<NativeCredential>(credentialPointer);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0)
            {
                return null;
            }

            var bytes = new byte[credential.CredentialBlobSize];
            try
            {
                Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
                var json = Encoding.Unicode.GetString(bytes);
                return JsonSerializer.Deserialize<GoogleOAuthStoredCredential>(json, JsonOptions);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(bytes);
            }
        }
        catch (JsonException ex)
        {
            throw new InvalidOperationException("Credential Manager payload could not be decoded.", ex);
        }
        finally
        {
            CredFree(credentialPointer);
        }
    }

    public void Save(GoogleOAuthStoredCredential credential)
    {
        var json = JsonSerializer.Serialize(credential, JsonOptions);
        var bytes = Encoding.Unicode.GetBytes(json);
        var blob = Marshal.AllocCoTaskMem(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var nativeCredential = new NativeCredential
            {
                Type = CredentialTypeGeneric,
                TargetName = _targetName,
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blob,
                Persist = CredentialPersistLocalMachine,
                UserName = DefaultAccountName
            };

            if (!CredWriteW(ref nativeCredential, 0))
            {
                var error = Marshal.GetLastWin32Error();
                throw new InvalidOperationException($"Credential Manager write failed: {error}");
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            Marshal.FreeCoTaskMem(blob);
        }
    }

    public void Delete()
    {
        if (CredDeleteW(_targetName, CredentialTypeGeneric, 0))
        {
            return;
        }

        var error = Marshal.GetLastWin32Error();
        if (error != ErrorNotFound)
        {
            throw new InvalidOperationException($"Credential Manager delete failed: {error}");
        }
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(
        string targetName,
        uint type,
        uint flags,
        out IntPtr credential);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(
        ref NativeCredential credential,
        uint flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(
        string targetName,
        uint type,
        uint flags);

    [DllImport("advapi32.dll", SetLastError = false)]
    private static extern void CredFree(IntPtr buffer);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeCredential
    {
        public uint Flags;
        public uint Type;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string TargetName;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string? TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string UserName;
    }
}

internal interface IOpenAIRealtimeCredentialStore
{
    bool HasCredential();
    OpenAIRealtimeApiKey? Load();
    void Save(OpenAIRealtimeApiKey apiKey);
    void Delete();
}

internal static class OpenAIRealtimeCredentialStoreFactory
{
    public static IOpenAIRealtimeCredentialStore Create(HoverPocketApplicationData applicationData)
    {
        ArgumentNullException.ThrowIfNull(applicationData);
        return applicationData.IsIsolatedVoiceE2E
            ? new EphemeralOpenAIRealtimeCredentialStore()
            : new OpenAIRealtimeCredentialStore(applicationData.OpenAIRealtimeCredentialTarget);
    }
}

internal sealed class EphemeralOpenAIRealtimeCredentialStore : IOpenAIRealtimeCredentialStore
{
    private readonly object _sync = new();
    private byte[]? _secret;

    public bool HasCredential()
    {
        lock (_sync)
        {
            return _secret is { Length: > 0 };
        }
    }

    public OpenAIRealtimeApiKey? Load()
    {
        lock (_sync)
        {
            if (_secret is not { Length: > 0 })
            {
                return null;
            }
            var copy = _secret.ToArray();
            try
            {
                return new OpenAIRealtimeApiKey(Encoding.UTF8.GetString(copy));
            }
            finally
            {
                CryptographicOperations.ZeroMemory(copy);
            }
        }
    }

    public void Save(OpenAIRealtimeApiKey apiKey)
    {
        ArgumentNullException.ThrowIfNull(apiKey);
        var replacement = apiKey.CopyUtf8Bytes();
        lock (_sync)
        {
            ClearLocked();
            _secret = replacement;
        }
    }

    public void Delete()
    {
        lock (_sync)
        {
            ClearLocked();
        }
    }

    private void ClearLocked()
    {
        if (_secret is null)
        {
            return;
        }
        CryptographicOperations.ZeroMemory(_secret);
        _secret = null;
    }
}

/// <summary>
/// A transient in-memory secret wrapper. It is intentionally not serializable and its
/// string/debug representation is always redacted.
/// </summary>
internal sealed class OpenAIRealtimeApiKey : IDisposable
{
    private char[] _characters;
    private bool _disposed;

    public OpenAIRealtimeApiKey(string value)
    {
        if (string.IsNullOrWhiteSpace(value)
            || value.EnumerateRunes().Count() is < 20 or > 512
            || value.Any(char.IsWhiteSpace)
            || value.Any(char.IsControl))
        {
            throw new InvalidOperationException("OpenAI Realtime API key is invalid.");
        }
        _characters = value.ToCharArray();
    }

    internal string Reveal()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return new string(_characters);
    }

    internal byte[] CopyUtf8Bytes()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return Encoding.UTF8.GetBytes(_characters);
    }

    public override string ToString() => "[redacted]";

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        Array.Clear(_characters);
        _characters = [];
        _disposed = true;
    }
}

/// <summary>
/// Host-only Credential Manager storage for the OpenAI Realtime BYOK key. The payload
/// is raw UTF-8 secret bytes, never JSON, and no public state contains the secret.
/// </summary>
internal sealed class OpenAIRealtimeCredentialStore : IOpenAIRealtimeCredentialStore
{
    private const uint CredentialTypeGeneric = 1;
    private const uint CredentialPersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;
    private const string DefaultTargetName = "HoverPocket.OpenAIRealtime.ApiKey.v1";
    private const string AccountName = "default";
    private readonly string _targetName;

    public OpenAIRealtimeCredentialStore(string targetName = DefaultTargetName)
    {
        _targetName = targetName;
    }

    public bool HasCredential()
    {
        if (!CredReadW(_targetName, CredentialTypeGeneric, 0, out var pointer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == ErrorNotFound)
            {
                return false;
            }
            throw new InvalidOperationException($"Credential Manager read failed: {error}");
        }
        try
        {
            var credential = Marshal.PtrToStructure<NativeOpenAICredential>(pointer);
            return credential.CredentialBlob != IntPtr.Zero && credential.CredentialBlobSize > 0;
        }
        finally
        {
            CredFree(pointer);
        }
    }

    public OpenAIRealtimeApiKey? Load()
    {
        if (!CredReadW(_targetName, CredentialTypeGeneric, 0, out var pointer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == ErrorNotFound)
            {
                return null;
            }
            throw new InvalidOperationException($"Credential Manager read failed: {error}");
        }
        try
        {
            var credential = Marshal.PtrToStructure<NativeOpenAICredential>(pointer);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0)
            {
                return null;
            }
            if (credential.CredentialBlobSize > 2_048)
            {
                throw new InvalidOperationException("Credential Manager payload is invalid.");
            }
            var bytes = new byte[credential.CredentialBlobSize];
            try
            {
                Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
                return new OpenAIRealtimeApiKey(Encoding.UTF8.GetString(bytes));
            }
            finally
            {
                CryptographicOperations.ZeroMemory(bytes);
            }
        }
        finally
        {
            CredFree(pointer);
        }
    }

    public void Save(OpenAIRealtimeApiKey apiKey)
    {
        ArgumentNullException.ThrowIfNull(apiKey);
        var bytes = apiKey.CopyUtf8Bytes();
        var blob = Marshal.AllocCoTaskMem(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new NativeOpenAICredential
            {
                Type = CredentialTypeGeneric,
                TargetName = _targetName,
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blob,
                Persist = CredentialPersistLocalMachine,
                UserName = AccountName
            };
            if (!CredWriteW(ref credential, 0))
            {
                var error = Marshal.GetLastWin32Error();
                throw new InvalidOperationException($"Credential Manager write failed: {error}");
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            Marshal.FreeCoTaskMem(blob);
        }
    }

    public void Delete()
    {
        if (CredDeleteW(_targetName, CredentialTypeGeneric, 0))
        {
            return;
        }
        var error = Marshal.GetLastWin32Error();
        if (error != ErrorNotFound)
        {
            throw new InvalidOperationException($"Credential Manager delete failed: {error}");
        }
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string targetName, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(ref NativeOpenAICredential credential, uint flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string targetName, uint type, uint flags);

    [DllImport("advapi32.dll", SetLastError = false)]
    private static extern void CredFree(IntPtr buffer);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeOpenAICredential
    {
        public uint Flags;
        public uint Type;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
        [MarshalAs(UnmanagedType.LPWStr)] public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        [MarshalAs(UnmanagedType.LPWStr)] public string? TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
    }
}
