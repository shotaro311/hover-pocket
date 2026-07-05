using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace S2.ClipboardDragOut;

internal static class SpikeVerifier
{
    public static async Task<int> RunAsync()
    {
        Console.WriteLine("S2 verify: clipboard listener + drag data formats");

        var window = new MainWindow
        {
            Left = 40,
            Top = 40,
        };

        try
        {
            window.Show();
            await WaitForDispatcherAsync();

            var text = $"HoverPocket S2 verify {Guid.NewGuid():N}";
            Clipboard.SetText(text, TextDataFormat.UnicodeText);
            var gotText = await window.WaitForItemAsync(item => item.Kind == ClipboardItemKind.Text && item.Text == text, TimeSpan.FromSeconds(3));

            var bitmap = MainWindow.CreateProbeBitmap();
            Clipboard.SetImage(bitmap);
            var gotImage = await window.WaitForItemAsync(item => item.Kind == ClipboardItemKind.Image && item.PngBytes is { Length: > 0 }, TimeSpan.FromSeconds(3));

            var textItem = window.History.FirstOrDefault(item => item.Kind == ClipboardItemKind.Text && item.Text == text);
            var imageItem = window.History.FirstOrDefault(item => item.Kind == ClipboardItemKind.Image);
            var textData = textItem is not null ? window.BuildDragDataObject(textItem) : null;
            var imageData = imageItem is not null ? window.BuildDragDataObject(imageItem) : null;

            var hasUnicodeText = textData?.GetDataPresent(DataFormats.UnicodeText) == true;
            var hasBitmap = imageData?.GetDataPresent(DataFormats.Bitmap) == true;
            var hasFileDrop = imageData?.GetDataPresent(DataFormats.FileDrop) == true;
            var pngFileExists = imageItem?.PngPath is not null && File.Exists(imageItem.PngPath);

            Console.WriteLine($"S2 listener.text={gotText}");
            Console.WriteLine($"S2 listener.image={gotImage}");
            Console.WriteLine($"S2 drag.unicodeText={hasUnicodeText}");
            Console.WriteLine($"S2 drag.bitmap={hasBitmap}");
            Console.WriteLine($"S2 drag.fileDrop={hasFileDrop}");
            Console.WriteLine($"S2 image.pngFileExists={pngFileExists}");
            Console.WriteLine("S2 external drop into Notepad/Explorer requires manual pointer test.");

            return gotText && gotImage && hasUnicodeText && hasBitmap && hasFileDrop && pngFileExists ? 0 : 1;
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
}
