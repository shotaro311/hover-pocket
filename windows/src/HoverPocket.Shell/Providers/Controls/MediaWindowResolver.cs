using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace HoverPocket.Shell.Providers.Controls;

internal sealed class MediaSourceActivator : IMediaSourceActivator
{
    public bool TryActivate(nint? windowHandle)
    {
        return MediaWindowResolver.TryActivate(windowHandle);
    }
}

internal static class MediaWindowResolver
{
    private const uint GetWindowOwner = 4;
    private const int ShowRestore = 9;

    public static bool TryActivate(nint? windowHandle)
    {
        if (windowHandle is not { } window || window == IntPtr.Zero || !IsWindow(window))
        {
            return false;
        }

        if (IsIconic(window))
        {
            _ = ShowWindowAsync(window, ShowRestore);
        }

        return SetForegroundWindow(window);
    }

    public static nint? ResolveUnique(string sourceAppUserModelId, string mediaTitle)
    {
        var source = Normalize(sourceAppUserModelId);
        var title = Normalize(mediaTitle);
        if (source.Length < 3 || title.Length < 3)
        {
            return null;
        }

        var candidates = new List<WindowCandidate>();
        _ = EnumWindows((window, parameter) =>
        {
            _ = parameter;
            if (!IsWindowVisible(window)
                || GetWindow(window, GetWindowOwner) != IntPtr.Zero
                || window == GetShellWindow())
            {
                return true;
            }

            var windowTitle = ReadWindowTitle(window);
            if (string.IsNullOrWhiteSpace(windowTitle))
            {
                return true;
            }

            _ = GetWindowThreadProcessId(window, out var processId);
            if (processId == 0 || processId == (uint)Environment.ProcessId)
            {
                return true;
            }

            string processName;
            try
            {
                using var process = Process.GetProcessById((int)processId);
                processName = process.ProcessName;
            }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException)
            {
                return true;
            }

            var normalizedProcess = Normalize(processName);
            var normalizedWindowTitle = Normalize(windowTitle);
            var sourceMatches = SourceMatchesProcess(source, normalizedProcess);
            var titleMatches = normalizedWindowTitle.Contains(title, StringComparison.Ordinal)
                || title.Contains(normalizedWindowTitle, StringComparison.Ordinal);
            if (!sourceMatches || !titleMatches)
            {
                return true;
            }

            var score = 10 + Math.Min(title.Length, 80);
            candidates.Add(new WindowCandidate(window, score));
            return true;
        }, IntPtr.Zero);

        if (candidates.Count == 0)
        {
            return null;
        }

        var ordered = candidates.OrderByDescending(candidate => candidate.Score).ToArray();
        return ordered.Length == 1 || ordered[0].Score > ordered[1].Score
            ? ordered[0].Handle
            : null;
    }

    internal static nint? ResolveUniqueProcessWindowForVerification(
        string expectedProcessName,
        string? requiredTitleToken = null)
    {
        var expected = Normalize(expectedProcessName);
        var titleToken = Normalize(requiredTitleToken);
        var candidates = new List<nint>();
        _ = EnumWindows((window, parameter) =>
        {
            _ = parameter;
            var windowTitle = ReadWindowTitle(window);
            if (!IsWindowVisible(window)
                || GetWindow(window, GetWindowOwner) != IntPtr.Zero
                || string.IsNullOrWhiteSpace(windowTitle)
                || (titleToken.Length > 0 && !Normalize(windowTitle).Contains(titleToken, StringComparison.Ordinal)))
            {
                return true;
            }

            _ = GetWindowThreadProcessId(window, out var processId);
            if (processId == 0 || processId == (uint)Environment.ProcessId)
            {
                return true;
            }

            try
            {
                using var process = Process.GetProcessById((int)processId);
                if (Normalize(process.ProcessName) == expected)
                {
                    candidates.Add(window);
                }
            }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException)
            {
            }

            return true;
        }, IntPtr.Zero);
        return candidates.Count == 1 ? candidates[0] : null;
    }

    private static bool SourceMatchesProcess(string source, string process)
    {
        if (source.Contains(process, StringComparison.Ordinal)
            || process.Contains(source, StringComparison.Ordinal))
        {
            return true;
        }

        return (source.Contains("chrome", StringComparison.Ordinal) && process == "chrome")
            || (source.Contains("msedge", StringComparison.Ordinal) && process == "msedge")
            || (source.Contains("firefox", StringComparison.Ordinal) && process == "firefox")
            || (source.Contains("brave", StringComparison.Ordinal) && process == "brave")
            || (source.Contains("vivaldi", StringComparison.Ordinal) && process == "vivaldi")
            || (source.Contains("opera", StringComparison.Ordinal) && process.Contains("opera", StringComparison.Ordinal));
    }

    private static string Normalize(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return string.Empty;
        }

        var builder = new StringBuilder(value.Length);
        foreach (var character in value.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(character))
            {
                builder.Append(character);
            }
        }

        return builder.ToString();
    }

    private static string ReadWindowTitle(IntPtr window)
    {
        var length = GetWindowTextLengthW(window);
        if (length <= 0)
        {
            return string.Empty;
        }

        var buffer = new StringBuilder(length + 1);
        _ = GetWindowTextW(window, buffer, buffer.Capacity);
        return buffer.ToString();
    }

    private sealed record WindowCandidate(nint Handle, int Score);

    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindow(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindowAsync(IntPtr window, int command);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);

    [DllImport("user32.dll")]
    private static extern IntPtr GetShellWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLengthW(IntPtr window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr window, StringBuilder buffer, int maximumCount);
}
