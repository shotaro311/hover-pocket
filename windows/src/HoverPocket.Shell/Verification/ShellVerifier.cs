using HoverPocket.Shell.Interop;
using HoverPocket.Shell.Windows;
using System.Diagnostics;

namespace HoverPocket.Shell.Verification;

internal sealed class ShellVerifier
{
    private const int StressCycles = 25;
    private readonly HoverShellController _controller;
    private readonly List<string> _failures = [];

    public ShellVerifier(HoverShellController controller)
    {
        _controller = controller;
    }

    public async Task<int> RunAsync()
    {
        await Task.Delay(200);

        var beforeWindowCount = _controller.CountCurrentProcessTopLevelWindows();
        if (_controller.AccessSurfaces.Count == 0)
        {
            _failures.Add("access surface: no windows created");
        }

        for (var index = 0; index < _controller.AccessSurfaces.Count; index++)
        {
            VerifyWindow($"access surface {index}", _controller.AccessSurfaces[index].Hwnd);
        }

        VerifyWindow("panel", _controller.Panel.Hwnd);
        await VerifySecondInstanceAsync();

        for (var cycle = 0; cycle < StressCycles; cycle++)
        {
            await _controller.ShowPanelForVerifyAsync();
            await Task.Delay(20);
            await _controller.HidePanelForVerifyAsync();
            await Task.Delay(20);
        }

        var afterWindowCount = _controller.CountCurrentProcessTopLevelWindows();
        if (afterWindowCount != beforeWindowCount)
        {
            _failures.Add($"top-level window count changed: before={beforeWindowCount}, after={afterWindowCount}");
        }

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine($"PASS shell verify: windows={afterWindowCount}, cycles={StressCycles}");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL shell verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private void VerifyWindow(string name, IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            _failures.Add($"{name}: HWND is zero");
            return;
        }

        var styles = NativeMethods.GetExtendedStyles(hwnd);
        CheckStyle(name, styles, NativeMethods.WsExNoActivate, "WS_EX_NOACTIVATE");
        CheckStyle(name, styles, NativeMethods.WsExToolWindow, "WS_EX_TOOLWINDOW");
        CheckStyle(name, styles, NativeMethods.WsExTopmost, "WS_EX_TOPMOST");
    }

    private void CheckStyle(string name, long styles, long expected, string label)
    {
        if ((styles & expected) != expected)
        {
            _failures.Add($"{name}: missing {label}; exStyle=0x{styles:X}");
        }
    }

    private async Task VerifySecondInstanceAsync()
    {
        var processPath = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(processPath))
        {
            _failures.Add("second instance: current process path is unavailable");
            return;
        }

        using var process = Process.Start(new ProcessStartInfo(processPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            ArgumentList = { "--second-instance-probe" }
        });

        if (process is null)
        {
            _failures.Add("second instance: process failed to start");
            return;
        }

        var completed = await Task.Run(() => process.WaitForExit(5000));
        if (!completed)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
            }

            _failures.Add("second instance: process did not exit within 5s");
            return;
        }

        if (process.ExitCode != 0)
        {
            _failures.Add($"second instance: exit code {process.ExitCode}");
        }
    }
}
