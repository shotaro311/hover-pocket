using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using Panel = System.Windows.Controls.Panel;

namespace HoverPocket.Shell.Capture;

internal sealed class InlineImageEditor
{
    private readonly TaskCompletionSource<bool> _completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public void Cancel() => _completion.TrySetResult(false);

    public async Task<bool> ShowAsync(Window owner, FrameworkElement webSurface, CoreWebView2 web, BitmapSource image, Func<EditedScreenshot, Task> save)
    {
        if (webSurface.Parent is not Panel host) throw new InvalidOperationException("編集画面を表示できませんでした。");
        var editor = new ScreenshotEditorView(image, existingAsset: true, compact: true) { SaveAsync = save };
        var visibility = webSurface.Visibility;
        editor.Finished += result => _completion.TrySetResult(result is not null);
        void OnClosed(object? sender, EventArgs args) => Cancel();
        owner.Closed += OnClosed;
        try
        {
            if (webSurface is WebView2CompositionControl)
            {
                var headerRatio = System.Text.Json.JsonSerializer.Deserialize<double>(await web.ExecuteScriptAsync(
                    "(document.querySelector('.hp-header')?.getBoundingClientRect().bottom || 0) / innerWidth"));
                editor.Margin = new Thickness(0, Math.Clamp(headerRatio * webSurface.ActualWidth, 0, webSurface.ActualHeight), 0, 0);
            }
            if (_completion.Task.IsCompleted) return false;
            // Preserve the live shell header above the editor. The organizer has
            // no shell header and uses an HWND browser that must be hidden.
            Panel.SetZIndex(editor, Panel.GetZIndex(webSurface) + 1);
            host.Children.Add(editor);
            if (editor.Margin.Top == 0) webSurface.Visibility = Visibility.Hidden;
            owner.Activate();
            editor.Focus();
            return await _completion.Task;
        }
        finally
        {
            owner.Closed -= OnClosed;
            host.Children.Remove(editor);
            webSurface.Visibility = visibility;
            if (owner.IsVisible) webSurface.Focus();
        }
    }
}
