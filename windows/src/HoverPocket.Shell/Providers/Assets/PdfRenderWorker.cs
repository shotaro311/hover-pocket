using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Windows.Data.Pdf;
using Windows.Storage;
using Windows.Storage.Streams;

namespace HoverPocket.Shell.Providers.Assets;

internal sealed record PdfRenderRequest(string Path, int Page, int MaximumDimension);

internal static class PdfRenderWorker
{
    public const string Argument = "--asset-pdf-render-worker";
    public static void Run()
    {
        uint exitCode = 1;
        Console.InputEncoding = new UTF8Encoding(false);
        Console.OutputEncoding = new UTF8Encoding(false);
        try
        {
            while (Console.ReadLine() is { } line)
            {
                var request = JsonSerializer.Deserialize<PdfRenderRequest>(line)!;
                var frame = Task.Run(() => RenderAsync(request)).GetAwaiter().GetResult();
                Console.WriteLine(JsonSerializer.Serialize(frame));
                Console.Out.Flush();
            }
            exitCode = 0;
        }
        finally
        {
            // This process owns no persistent writes. The OS releases its GPU resources without
            // invoking the faulty Windows.Data.Pdf -> DXGI process-detach destructor chain.
            TerminateProcess(GetCurrentProcess(), exitCode);
        }
    }

    private static async Task<AssetFrame> RenderAsync(PdfRenderRequest request)
    {
        try
        {
            if (!System.IO.Path.IsPathFullyQualified(request.Path) || request.MaximumDimension is < 1 or > 2048)
                throw new ArgumentException("Invalid PDF rendering request.");
            var file = await StorageFile.GetFileFromPathAsync(request.Path);
            var loading = PdfDocument.LoadFromFileAsync(file, "");
            PdfDocument pdf;
            try { pdf = await loading; } finally { loading.Close(); }
            using var pdfNative = ((WinRT.IWinRTObject)pdf).NativeObject;
            var interfaceType = System.Reflection.CustomAttributeExtensions.GetCustomAttribute<WinRT.ProjectedRuntimeClassAttribute>(typeof(PdfDocument))!.DefaultInterface!;
            using var pdfInterface = ((WinRT.IWinRTObject)pdf).GetObjectReferenceForType(interfaceType.TypeHandle);
            var pages = checked((int)pdf.PageCount);
            using var page = pdf.GetPage((uint)Math.Clamp(request.Page - 1, 0, pages - 1));
            var width = page.Size.Width; var height = page.Size.Height;
            using var output = new InMemoryRandomAccessStream();
            var scale = Math.Min(1, request.MaximumDimension / Math.Max(width, height));
            await page.RenderToStreamAsync(output, new PdfPageRenderOptions
            {
                DestinationWidth = (uint)Math.Max(1, width * scale), DestinationHeight = (uint)Math.Max(1, height * scale)
            });
            output.Seek(0);
            using var input = output.AsStreamForRead(); using var bytes = new MemoryStream();
            await input.CopyToAsync(bytes);
            return new("data:image/png;base64," + Convert.ToBase64String(bytes.ToArray()), width, height, pages, ContentType: "image/png");
        }
        catch (Exception ex) when (ex.HResult == unchecked((int)0x8007052B))
        { return new(null, 0, 0, Error: "パスワードで保護されたPDFです。原本は保存済みです。OSで開くか、保護を解除したファイルを追加してください。"); }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        { return new(null, 0, 0, Error: "PDFを描画できません。形式・破損・保護を確認してください。原本は保存されています。"); }
    }

    [DllImport("kernel32.dll")] private static extern nint GetCurrentProcess();
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool TerminateProcess(nint process, uint exitCode);
}

internal sealed class PdfRenderClient
{
    private Process? _process;
    private readonly SemaphoreSlim _operation = new(1, 1);
    private CancellationTokenSource? _idle;
    public async Task<AssetFrame> RenderAsync(string path, int page, int maximumDimension, CancellationToken token)
    {
        await _operation.WaitAsync(token);
        var previousIdle = _idle; _idle = null; previousIdle?.Cancel();
        try
        {
            if (_process is null || _process.HasExited)
            {
                Stop();
                _process = Process.Start(new ProcessStartInfo(System.IO.Path.Combine(AppContext.BaseDirectory, "HoverPocket.Shell.exe"), PdfRenderWorker.Argument)
                {
                    UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
                    RedirectStandardInput = true, RedirectStandardOutput = true,
                    StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false)
                }) ?? throw new IOException("PDF renderer did not start.");
            }
            await _process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new PdfRenderRequest(path, page, maximumDimension)).AsMemory(), token);
            await _process.StandardInput.FlushAsync(token);
            var response = await _process.StandardOutput.ReadLineAsync(token).AsTask().WaitAsync(TimeSpan.FromSeconds(30), token);
            if (response is null || response.Length > 32 * 1024 * 1024) throw new IOException("PDF renderer disconnected.");
            return JsonSerializer.Deserialize<AssetFrame>(response) ?? throw new IOException("Invalid PDF response.");
        }
        catch { Stop(); throw; }
        finally { _idle = new(); _ = StopWhenIdleAsync(_idle); _operation.Release(); }
    }
    private async Task StopWhenIdleAsync(CancellationTokenSource idle)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(30), idle.Token);
            await _operation.WaitAsync(idle.Token);
            try { if (ReferenceEquals(_idle, idle)) { _idle = null; Stop(); } } finally { _operation.Release(); }
        }
        catch (OperationCanceledException) { }
        finally { idle.Dispose(); }
    }
    internal async Task StopForVerifyAsync()
    {
        await _operation.WaitAsync(); try { Stop(); } finally { _operation.Release(); }
    }
    private void Stop()
    {
        if (_process is null) return;
        try { if (!_process.HasExited) _process.Kill(); } catch (InvalidOperationException) { }
        _process.Dispose(); _process = null;
    }
}
