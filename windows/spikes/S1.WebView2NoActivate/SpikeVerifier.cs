using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace S1.WebView2NoActivate;

internal static class SpikeVerifier
{
    public static async Task<int> RunAsync()
    {
        Console.WriteLine("S1 verify: WebView2 + NOACTIVATE overlay");
        Console.WriteLine($"S1 webview.runtime={GetRuntimeVersion()}");

        var cases = new[]
        {
            OverlayOptions.BaselineOpaque,
            OverlayOptions.NoActivateOpaque,
            OverlayOptions.Target,
        };

        var results = new List<CaseResult>();
        foreach (var options in cases)
        {
            results.Add(await RunCaseAsync(options));
        }

        foreach (var result in results)
        {
            Console.WriteLine($"S1 case={result.Name}");
            Console.WriteLine($"S1 {result.Name}.passed={result.Passed}");
            Console.WriteLine($"S1 {result.Name}.initialized={result.Initialized}");
            Console.WriteLine($"S1 {result.Name}.script={result.ScriptProbe}");
            Console.WriteLine($"S1 {result.Name}.noactivateStyle={result.NoActivateStyle}");
            Console.WriteLine($"S1 {result.Name}.toolwindowStyle={result.ToolWindowStyle}");
            Console.WriteLine($"S1 {result.Name}.transparent={result.Transparent}");
            Console.WriteLine($"S1 {result.Name}.foregroundUnchanged={result.ForegroundUnchanged}");
            Console.WriteLine($"S1 {result.Name}.processFailures={string.Join(",", result.ProcessFailures)}");
            if (result.Error is not null)
            {
                Console.WriteLine($"S1 {result.Name}.error={result.Error}");
            }
        }

        Console.WriteLine("S1 click-focus behavior still requires manual pointer test.");

        var baseline = results.First(result => result.Name == OverlayOptions.BaselineOpaque.Name);
        var target = results.First(result => result.Name == OverlayOptions.Target.Name);
        if (!baseline.Passed)
        {
            return 1;
        }

        return target.Passed ? 0 : 2;
    }

    private static async Task<CaseResult> RunCaseAsync(OverlayOptions options)
    {
        var foregroundBefore = NativeMethods.GetForegroundWindow();
        var window = new MainWindow(options);

        try
        {
            window.Show();
            await WaitForDispatcherAsync();
            var initialized = await WithTimeout(window.InitializeWebViewAsync(), TimeSpan.FromSeconds(12));
            if (!initialized)
            {
                return CaseResult.Failed(options.Name, initialized: false, error: "webview init timeout");
            }

            await Task.Delay(900);

            var foregroundAfter = NativeMethods.GetForegroundWindow();
            var text = await window.ReadProbeTextAsync();
            var transparent = window.Web.DefaultBackgroundColor.A == 0;
            var foregroundUnchanged = foregroundBefore == IntPtr.Zero || foregroundAfter == foregroundBefore;

            var styleOk = !options.UseNoActivate || (window.HasNoActivateStyle && window.HasToolWindowStyle);
            var transparentOk = options.TransparentBackground == transparent;
            var foregroundOk = !options.UseNoActivate || foregroundUnchanged;
            var scriptOk = text.Contains("WebView2 in NOACTIVATE overlay", StringComparison.Ordinal);
            var passed = initialized && styleOk && transparentOk && foregroundOk && scriptOk && window.ProcessFailures.Count == 0;

            return new CaseResult(
                options.Name,
                passed,
                initialized,
                text,
                window.HasNoActivateStyle,
                window.HasToolWindowStyle,
                transparent,
                foregroundUnchanged,
                window.ProcessFailures.ToArray(),
                null);
        }
        catch (Exception ex)
        {
            return CaseResult.Failed(options.Name, initialized: true, error: ex.GetType().Name + ": " + ex.Message);
        }
        finally
        {
            window.Close();
            await Task.Delay(250);
        }
    }

    private static Task WaitForDispatcherAsync()
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Dispatcher.CurrentDispatcher.BeginInvoke(() => completion.SetResult(), DispatcherPriority.ApplicationIdle);
        return completion.Task;
    }

    private static async Task<bool> WithTimeout(Task task, TimeSpan timeout)
    {
        var completed = await Task.WhenAny(task, Task.Delay(timeout));
        if (completed != task)
        {
            return false;
        }

        await task;
        return true;
    }

    private static string GetRuntimeVersion()
    {
        try
        {
            return CoreWebView2Environment.GetAvailableBrowserVersionString();
        }
        catch (Exception ex)
        {
            return ex.GetType().Name + ": " + ex.Message;
        }
    }

    private sealed record CaseResult(
        string Name,
        bool Passed,
        bool Initialized,
        string ScriptProbe,
        bool NoActivateStyle,
        bool ToolWindowStyle,
        bool Transparent,
        bool ForegroundUnchanged,
        IReadOnlyList<string> ProcessFailures,
        string? Error)
    {
        public static CaseResult Failed(string name, bool initialized, string error)
        {
            return new CaseResult(name, false, initialized, string.Empty, false, false, false, false, [], error);
        }
    }
}
