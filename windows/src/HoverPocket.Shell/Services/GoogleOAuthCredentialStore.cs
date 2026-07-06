using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

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
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            var json = Encoding.Unicode.GetString(bytes);
            return JsonSerializer.Deserialize<GoogleOAuthStoredCredential>(json, JsonOptions);
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
