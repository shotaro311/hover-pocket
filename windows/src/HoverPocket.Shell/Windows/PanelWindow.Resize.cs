using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using HoverPocket.Shell.Display;
using Cursors = System.Windows.Input.Cursors;
using Brushes = System.Windows.Media.Brushes;
using HorizontalAlignment = System.Windows.HorizontalAlignment;

namespace HoverPocket.Shell.Windows;

internal sealed partial class PanelWindow
{
    internal event Action<double, double, bool>? UserResize;
    private Thumb? _resizeGrip;
    internal Thumb ResizeGripForVerify => _resizeGrip!;
    private void InitializeResizeGrip()
    {
        var grip = new Thumb { Width = 22, Height = 22, HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 3, 3), Cursor = Cursors.SizeNWSE,
            ToolTip = "ドラッグしてパネルの大きさを変更", Focusable = false };
        var label = new FrameworkElementFactory(typeof(TextBlock));
        label.SetValue(TextBlock.TextProperty, "◢"); label.SetValue(TextBlock.ForegroundProperty, Brushes.SlateGray);
        label.SetValue(TextBlock.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        label.SetValue(TextBlock.VerticalAlignmentProperty, VerticalAlignment.Center);
        grip.Template = new ControlTemplate(typeof(Thumb)) { VisualTree = label };
        System.Windows.Automation.AutomationProperties.SetName(grip, "パネルの大きさを変更");
        grip.DragStarted += (_, _) => UserResize?.Invoke(0, 0, false);
        grip.DragDelta += (_, args) => UserResize?.Invoke(args.HorizontalChange, args.VerticalChange, false);
        grip.DragCompleted += (_, _) => UserResize?.Invoke(0, 0, true);
        System.Windows.Controls.Panel.SetZIndex(grip, 100);
        _resizeGrip = grip;
        _root.Children.Add(grip);
    }
    internal void ResizeLive(WindowPlacement target)
    {
        SetLiquidTarget(target, snap: true);
        CancelResizeImage();
        ApplyLiquidSurface();
    }
}
