using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;

namespace HoverPocket.CodexSandboxSetup;

internal static class CodexSetupReadbackVerifier
{
    private const int CodexSetupVersion = 5;
    private const int MaximumReadbackBytes = 64 * 1024;
    private const int MaximumEncryptedPasswordBytes = 16 * 1024;
    private const int ExpectedPasswordBytes = 24;
    private const string AllowedPasswordCharacters =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-_=+";
    private const uint CryptProtectUiForbidden = 0x1;
    private const uint CryptProtectLocalMachine = 0x4;
    private static readonly JsonDocumentOptions JsonOptions = new()
    {
        AllowTrailingCommas = false,
        CommentHandling = JsonCommentHandling.Disallow,
        MaxDepth = 8,
    };

    internal static void Verify(string codexHome)
    {
        var markerPath = Path.Combine(codexHome, ".sandbox", "setup_marker.json");
        var usersPath = Path.Combine(codexHome, ".sandbox-secrets", "sandbox_users.json");
        VerifyMarkerDocument(ReadBoundedRegularFile(markerPath));
        VerifySandboxUsersDocument(
            ReadBoundedRegularFile(usersPath),
            UnprotectMachineScope);
    }

    internal static void VerifyMarkerDocument(ReadOnlyMemory<byte> json)
    {
        try
        {
            using var marker = JsonDocument.Parse(json, JsonOptions);
            var root = marker.RootElement;
            if (!HasExactProperties(
                root,
                "version",
                "offline_username",
                "online_username",
                "created_at",
                "proxy_ports",
                "allow_local_binding",
                "read_roots",
                "write_roots")
                || !TryGetExactInt32(root, "version", CodexSetupVersion)
                || !TryGetExactString(root, "offline_username", "CodexSandboxOffline")
                || !TryGetExactString(root, "online_username", "CodexSandboxOnline")
                || !TryGetRoundTripTimestamp(root, "created_at")
                || !TryGetEmptyArray(root, "proxy_ports")
                || !TryGetExactBoolean(root, "allow_local_binding", expected: false)
                || !TryGetEmptyArray(root, "read_roots")
                || !TryGetEmptyArray(root, "write_roots"))
            {
                throw new InvalidOperationException("HP_CODEX_SANDBOX_SETUP_MARKER_MISMATCH");
            }
        }
        catch (JsonException)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_SETUP_MARKER_MISMATCH");
        }
    }

    internal static void VerifySandboxUsersDocument(
        ReadOnlyMemory<byte> json,
        Func<byte[], byte[]> unprotect)
    {
        byte[]? offlinePlaintext = null;
        byte[]? onlinePlaintext = null;
        try
        {
            using var users = JsonDocument.Parse(json, JsonOptions);
            var root = users.RootElement;
            if (!HasExactProperties(root, "version", "offline", "online")
                || !TryGetExactInt32(root, "version", CodexSetupVersion)
                || !root.TryGetProperty("offline", out var offline)
                || !root.TryGetProperty("online", out var online))
            {
                throw UsersMismatch();
            }

            var offlineEncrypted = ReadUserRecord(
                offline,
                "CodexSandboxOffline");
            var onlineEncrypted = ReadUserRecord(
                online,
                "CodexSandboxOnline");
            offlinePlaintext = unprotect(offlineEncrypted);
            onlinePlaintext = unprotect(onlineEncrypted);
            VerifyPassword(offlinePlaintext);
            VerifyPassword(onlinePlaintext);
            if (CryptographicOperations.FixedTimeEquals(
                offlinePlaintext,
                onlinePlaintext))
            {
                throw UsersMismatch();
            }
        }
        catch (JsonException)
        {
            throw UsersMismatch();
        }
        catch (FormatException)
        {
            throw UsersMismatch();
        }
        finally
        {
            if (offlinePlaintext is not null)
            {
                CryptographicOperations.ZeroMemory(offlinePlaintext);
            }
            if (onlinePlaintext is not null)
            {
                CryptographicOperations.ZeroMemory(onlinePlaintext);
            }
        }
    }

    internal static void VerifyMachineScopeDpapiContractForSelfTest()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var offlinePlaintext = System.Text.Encoding.ASCII.GetBytes(
            "Abcdefghijklmnopqrstuv01");
        var onlinePlaintext = System.Text.Encoding.ASCII.GetBytes(
            "Zyxwvutsrqponmlkjihgfe98");
        try
        {
            var offlineEncrypted = ProtectMachineScope(offlinePlaintext);
            var onlineEncrypted = ProtectMachineScope(onlinePlaintext);
            var users = JsonSerializer.SerializeToUtf8Bytes(new
            {
                version = CodexSetupVersion,
                offline = new
                {
                    username = "CodexSandboxOffline",
                    password = Convert.ToBase64String(offlineEncrypted),
                },
                online = new
                {
                    username = "CodexSandboxOnline",
                    password = Convert.ToBase64String(onlineEncrypted),
                },
            });
            VerifySandboxUsersDocument(users, UnprotectMachineScope);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(offlinePlaintext);
            CryptographicOperations.ZeroMemory(onlinePlaintext);
        }
    }

    private static byte[] ReadBoundedRegularFile(string path)
    {
        var attributes = File.GetAttributes(path);
        var file = new FileInfo(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0
            || file.Length <= 0
            || file.Length > MaximumReadbackBytes)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_SETUP_READBACK_INVALID");
        }
        return File.ReadAllBytes(path);
    }

    private static byte[] ReadUserRecord(
        JsonElement record,
        string expectedUsername)
    {
        if (!HasExactProperties(record, "username", "password")
            || !TryGetExactString(record, "username", expectedUsername)
            || !record.TryGetProperty("password", out var passwordElement)
            || passwordElement.ValueKind != JsonValueKind.String)
        {
            throw UsersMismatch();
        }

        var encoded = passwordElement.GetString();
        if (string.IsNullOrWhiteSpace(encoded)
            || encoded.Length > MaximumEncryptedPasswordBytes * 2
            || encoded.Any(char.IsWhiteSpace))
        {
            throw UsersMismatch();
        }
        var encrypted = Convert.FromBase64String(encoded);
        if (encrypted.Length == 0
            || encrypted.Length > MaximumEncryptedPasswordBytes
            || !string.Equals(
                Convert.ToBase64String(encrypted),
                encoded,
                StringComparison.Ordinal))
        {
            throw UsersMismatch();
        }
        return encrypted;
    }

    private static void VerifyPassword(ReadOnlySpan<byte> password)
    {
        if (password.Length != ExpectedPasswordBytes)
        {
            throw UsersMismatch();
        }
        foreach (var character in password)
        {
            if (character > 0x7f
                || !AllowedPasswordCharacters.Contains(
                    (char)character,
                    StringComparison.Ordinal))
            {
                throw UsersMismatch();
            }
        }
    }

    private static bool HasExactProperties(
        JsonElement element,
        params string[] expectedProperties)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            return false;
        }
        var actualProperties = element.EnumerateObject()
            .Select(property => property.Name)
            .ToArray();
        return actualProperties.Length == expectedProperties.Length
            && actualProperties.Distinct(StringComparer.Ordinal).Count()
                == actualProperties.Length
            && expectedProperties.All(expected =>
                actualProperties.Contains(expected, StringComparer.Ordinal));
    }

    private static bool TryGetExactInt32(
        JsonElement root,
        string propertyName,
        int expected) =>
        root.TryGetProperty(propertyName, out var value)
        && value.ValueKind == JsonValueKind.Number
        && value.TryGetInt32(out var actual)
        && actual == expected;

    private static bool TryGetExactString(
        JsonElement root,
        string propertyName,
        string expected) =>
        root.TryGetProperty(propertyName, out var value)
        && value.ValueKind == JsonValueKind.String
        && string.Equals(value.GetString(), expected, StringComparison.Ordinal);

    private static bool TryGetExactBoolean(
        JsonElement root,
        string propertyName,
        bool expected) =>
        root.TryGetProperty(propertyName, out var value)
        && (expected
            ? value.ValueKind == JsonValueKind.True
            : value.ValueKind == JsonValueKind.False);

    private static bool TryGetEmptyArray(
        JsonElement root,
        string propertyName) =>
        root.TryGetProperty(propertyName, out var value)
        && value.ValueKind == JsonValueKind.Array
        && value.GetArrayLength() == 0;

    private static bool TryGetRoundTripTimestamp(
        JsonElement root,
        string propertyName)
    {
        if (!root.TryGetProperty(propertyName, out var value)
            || value.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        var encoded = value.GetString();
        return encoded is not null
            && (encoded.EndsWith('Z') || encoded.EndsWith("+00:00", StringComparison.Ordinal))
            && DateTimeOffset.TryParse(
                encoded,
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var timestamp)
            && timestamp.Offset == TimeSpan.Zero;
    }

    private static byte[] UnprotectMachineScope(byte[] encrypted)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException();
        }

        var inputPointer = Marshal.AllocHGlobal(encrypted.Length);
        try
        {
            Marshal.Copy(encrypted, 0, inputPointer, encrypted.Length);
            var input = new DataBlob((uint)encrypted.Length, inputPointer);
            if (!CryptUnprotectData(
                ref input,
                IntPtr.Zero,
                IntPtr.Zero,
                IntPtr.Zero,
                IntPtr.Zero,
                CryptProtectUiForbidden | CryptProtectLocalMachine,
                out var output))
            {
                throw UsersMismatch();
            }
            try
            {
                if (output.Data == IntPtr.Zero
                    || output.Size == 0
                    || output.Size > 1024)
                {
                    throw UsersMismatch();
                }
                var plaintext = new byte[output.Size];
                Marshal.Copy(output.Data, plaintext, 0, plaintext.Length);
                return plaintext;
            }
            finally
            {
                if (output.Data != IntPtr.Zero)
                {
                    Marshal.Copy(new byte[output.Size], 0, output.Data, (int)output.Size);
                    _ = LocalFree(output.Data);
                }
            }
        }
        finally
        {
            Marshal.FreeHGlobal(inputPointer);
        }
    }

    private static byte[] ProtectMachineScope(byte[] plaintext)
    {
        var inputPointer = Marshal.AllocHGlobal(plaintext.Length);
        try
        {
            Marshal.Copy(plaintext, 0, inputPointer, plaintext.Length);
            var input = new DataBlob((uint)plaintext.Length, inputPointer);
            if (!CryptProtectData(
                ref input,
                IntPtr.Zero,
                IntPtr.Zero,
                IntPtr.Zero,
                IntPtr.Zero,
                CryptProtectUiForbidden | CryptProtectLocalMachine,
                out var output))
            {
                throw UsersMismatch();
            }
            try
            {
                if (output.Data == IntPtr.Zero
                    || output.Size == 0
                    || output.Size > MaximumEncryptedPasswordBytes)
                {
                    throw UsersMismatch();
                }
                var encrypted = new byte[output.Size];
                Marshal.Copy(output.Data, encrypted, 0, encrypted.Length);
                return encrypted;
            }
            finally
            {
                if (output.Data != IntPtr.Zero)
                {
                    Marshal.Copy(new byte[output.Size], 0, output.Data, (int)output.Size);
                    _ = LocalFree(output.Data);
                }
            }
        }
        finally
        {
            Marshal.Copy(new byte[plaintext.Length], 0, inputPointer, plaintext.Length);
            Marshal.FreeHGlobal(inputPointer);
        }
    }

    private static InvalidOperationException UsersMismatch() =>
        new("HP_CODEX_SANDBOX_USERS_MISMATCH");

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct DataBlob(uint Size, IntPtr Data);

    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(
        ref DataBlob dataIn,
        IntPtr description,
        IntPtr optionalEntropy,
        IntPtr reserved,
        IntPtr prompt,
        uint flags,
        out DataBlob dataOut);

    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(
        ref DataBlob dataIn,
        IntPtr description,
        IntPtr optionalEntropy,
        IntPtr reserved,
        IntPtr prompt,
        uint flags,
        out DataBlob dataOut);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);
}
