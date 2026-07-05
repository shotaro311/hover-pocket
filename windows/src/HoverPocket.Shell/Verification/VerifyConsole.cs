using System.IO;
using HoverPocket.Shell.Interop;

namespace HoverPocket.Shell.Verification;

internal static class VerifyConsole
{
    // AttachConsole 経由の出力はリダイレクトされたパイプに乗らないため、
    // HOVERPOCKET_VERIFY_LOG にパスを指定するとファイルにも追記する(CI/自動検証用)。
    private static readonly string? LogPath = Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG");

    public static void AttachParent()
    {
        NativeMethods.AttachParentConsole();
    }

    public static void WriteLine(string message)
    {
        Console.WriteLine(message);
        if (!string.IsNullOrEmpty(LogPath))
        {
            try
            {
                File.AppendAllText(LogPath, message + Environment.NewLine);
            }
            catch (IOException)
            {
                // 検証ログの書き込み失敗で検証自体を壊さない。
            }
        }
    }
}
