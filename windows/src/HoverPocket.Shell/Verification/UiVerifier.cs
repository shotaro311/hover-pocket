using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell.Verification;

internal sealed class UiVerifier
{
    private readonly HoverShellController _controller;
    private readonly List<string> _failures = [];

    public UiVerifier(HoverShellController controller)
    {
        _controller = controller;
    }

    public async Task<int> RunAsync()
    {
        VerifyConsole.WriteLine("UI verify: WebView2 host + bridge + provider registry + settings");

        try
        {
            await _controller.ShowPanelForUiVerifyAsync();
            var ready = await _controller.Panel.WaitForUiReadyAsync(TimeSpan.FromSeconds(8));
            if (!ready)
            {
                _failures.Add("webview: UI did not report ready within 8s");
            }

            var result = ready ? await _controller.Panel.RunWebVerifyScriptAsync() : null;
            if (result is null)
            {
                _failures.Add("webview: verification script returned no result");
            }
            else
            {
                if (!result.EchoOk)
                {
                    _failures.Add("bridge: diagnostics.echo round-trip failed");
                }

                if (!result.ProviderSwitchOk)
                {
                    _failures.Add($"provider: switch failed from {result.OriginalProvider} to {result.SwitchedProvider}");
                }

                if (!result.SettingsWriteOk)
                {
                    _failures.Add($"settings: panel size write failed for {result.ProbePanelSize}");
                }
            }

            if (_controller.Panel.ProcessFailures.Count > 0)
            {
                _failures.Add("webview process failures: " + string.Join(",", _controller.Panel.ProcessFailures));
            }
        }
        catch (Exception ex)
        {
            _failures.Add(ex.GetType().Name + ": " + ex.Message);
        }

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS ui verify: webview initialized, bridge round-trip, provider switch, settings read/write");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL ui verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }
}
