using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace S3.WebView2Camera;

internal static class SpikeVerifier
{
    public static async Task<int> RunAsync()
    {
        Console.WriteLine("S3 verify: WebView2 getUserMedia camera");
        Console.WriteLine($"S3 webview.runtime={GetRuntimeVersion()}");

        var window = new MainWindow
        {
            Left = 80,
            Top = 80,
        };

        try
        {
            window.Show();
            await WaitForDispatcherAsync();
            var initialized = await WithTimeout(window.InitializeWebViewAsync(), TimeSpan.FromSeconds(12));
            if (!initialized)
            {
                Console.Error.WriteLine("S3 webview.initialized=False timeout");
                return 1;
            }

            var ready = await window.WaitForReadyAsync(TimeSpan.FromSeconds(8));
            Console.WriteLine($"S3 page.secureContext={ready.SecureContext}");
            Console.WriteLine($"S3 page.hasMediaDevices={ready.HasMediaDevices}");
            Console.WriteLine($"S3 page.href={ready.Href}");
            Console.WriteLine($"S3 webview.processFailures={string.Join(",", window.ProcessFailures)}");

            if (!ready.SecureContext || !ready.HasMediaDevices)
            {
                return 1;
            }

            var camera = await window.StartCameraProbeAsync(TimeSpan.FromSeconds(15));
            Console.WriteLine($"S3 camera.status={camera.Status}");
            Console.WriteLine($"S3 camera.detail={camera.Detail}");
            Console.WriteLine($"S3 camera.extra={camera.Extra}");
            Console.WriteLine($"S3 permission.cameraRequests={window.CameraPermissionRequests}");
            Console.WriteLine($"S3 webview.processFailures={string.Join(",", window.ProcessFailures)}");

            if (camera.Status != "started")
            {
                return 2;
            }

            var stopped = await window.StopCameraProbeAsync(TimeSpan.FromSeconds(5));
            Console.WriteLine($"S3 camera.stoppedByScript={stopped}");

            return stopped && window.CameraPermissionRequests > 0 ? 0 : 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 1;
        }
        finally
        {
            window.Close();
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
}
