using System.Windows.Input;
using Microsoft.Web.WebView2.Wpf;

namespace HoverPocket.Shell.Windows;

internal sealed class PanelWebView : WebView2CompositionControl
{
    protected override void OnMouseDoubleClick(MouseButtonEventArgs e)
    {
        // OnMouseDown already forwards both clicks. Forwarding again here makes
        // Chromium count the second click as the third, suppressing dblclick.
        // https://github.com/MicrosoftEdge/WebView2Feedback/issues/5099
    }
}
