using System.Diagnostics;
using System.Text.Json;

namespace HoverPocket.Shell.Services;

// Record code locations, never exception messages, document names or credentials.
internal static class AppDiagnostics
{
    private static readonly object Sync = new();
    private static string? _path;
    public static void Start(string root)
    {
        _path = Path.Combine(root, "diagnostics", $"session-{DateTime.UtcNow:yyyyMMdd-HHmmss}-{Environment.ProcessId}.jsonl");
        Record("process.start");
        AppDomain.CurrentDomain.UnhandledException += (_, args) => Record("process.unhandled", args.ExceptionObject as Exception);
        AppDomain.CurrentDomain.ProcessExit += (_, _) => Record("process.exit");
    }
    public static void Record(string action, Exception? exception = null)
    {
        if (_path is null) return;
        try
        {
            var entry = JsonSerializer.Serialize(new
            {
                utc = DateTimeOffset.UtcNow, pid = Environment.ProcessId, action,
                version = System.Reflection.CustomAttributeExtensions.GetCustomAttribute<System.Reflection.AssemblyInformationalVersionAttribute>(typeof(AppDiagnostics).Assembly)?.InformationalVersion,
                exception = exception?.GetType().FullName, hresult = exception?.HResult,
                frames = exception is null ? null : new StackTrace(exception, false).GetFrames().Take(16)
                    .Select(frame => frame.GetMethod()).Select(method => method?.DeclaringType?.FullName + "." + method?.Name).ToArray()
            });
            lock (Sync)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
                File.AppendAllText(_path, entry + Environment.NewLine);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }
}
