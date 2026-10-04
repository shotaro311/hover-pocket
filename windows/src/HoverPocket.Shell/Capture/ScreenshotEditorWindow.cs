using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace HoverPocket.Shell.Capture;

internal sealed record EditedScreenshot(BitmapSource Image, bool KeepOriginal);

internal sealed class ScreenshotEditorWindow : Window
{
    private readonly ScreenshotEditorView _editor;
    public EditedScreenshot? Result { get; private set; }
    public ScreenshotEditorWindow(BitmapSource original, bool existingAsset = false)
    {
        Title = "画像を編集 — HoverPocket"; Width = 1120; Height = 780; MinWidth = 740; MinHeight = 500;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(System.Windows.Media.Color.FromRgb(16, 18, 24));
        Width = Math.Min(Width, SystemParameters.WorkArea.Width * .9); Height = Math.Min(Height, SystemParameters.WorkArea.Height * .9);
        MinWidth = Math.Min(MinWidth, Width); MinHeight = Math.Min(MinHeight, Height);
        SourceInitialized += (_, _) => { var dark = 1; DwmSetWindowAttribute(new System.Windows.Interop.WindowInteropHelper(this).Handle, 20, ref dark, sizeof(int)); };
        _editor = new(original, existingAsset); Content = _editor;
        _editor.Finished += result => { Result = result; if (result is null) Close(); else DialogResult = true; };
    }
    internal BitmapSource RenderImage() => _editor.RenderImage();
    internal void AddAnnotationsForVerify() => _editor.AddAnnotationsForVerify();
    internal void Undo() => _editor.Undo();
    internal void Redo() => _editor.Redo();
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);
}
