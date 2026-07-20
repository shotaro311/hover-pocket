using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using HoverPocket.Shell.Configuration;
using WpfColor = System.Windows.Media.Color;

namespace HoverPocket.Shell.Windows;

internal sealed class AccessSurfaceWindow : NoActivateWindow
{
    public const double ExpandedWidth = 168;
    public const double CompactWidth = 72;
    public const double SurfaceWidth = ExpandedWidth;
    public const double SurfaceHeight = 9;

    private static readonly WpfColor DefaultBackgroundColor = WpfColor.FromArgb(238, 13, 15, 20);
    private static readonly WpfColor DefaultBorderColor = WpfColor.FromArgb(80, 255, 255, 255);
    private readonly Border _surface;
    private readonly Grid _handleIcon = new()
    {
        Width = 15,
        Height = 8,
        HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
        VerticalAlignment = System.Windows.VerticalAlignment.Center,
        IsHitTestVisible = false
    };

    public event EventHandler? HoverEntered;

    public AccessSurfaceWindow()
    {
        Width = ExpandedWidth;
        Height = SurfaceHeight;
        MinWidth = CompactWidth;
        MinHeight = SurfaceHeight;
        MaxWidth = ExpandedWidth;
        MaxHeight = SurfaceHeight;

        _surface = new Border
        {
            Background = new SolidColorBrush(DefaultBackgroundColor),
            BorderBrush = new SolidColorBrush(DefaultBorderColor),
            BorderThickness = new Thickness(1, 0, 1, 1),
            CornerRadius = new CornerRadius(0, 0, 7, 7),
            SnapsToDevicePixels = true,
            Child = _handleIcon
        };
        Content = _surface;

        MouseEnter += (_, _) => HoverEntered?.Invoke(this, EventArgs.Empty);
    }

    public void UpdateAppearance(UserSettings settings)
    {
        var width = settings.ShowTopHandleSideArea ? ExpandedWidth : CompactWidth;
        Width = width;
        _handleIcon.Children.Clear();
        switch (settings.HandleIconStyle)
        {
            case HandleIconStyle.C:
                AddPocketGlyph();
                break;
            case HandleIconStyle.None:
                break;
            default:
                AddChevronGlyph();
                break;
        }
    }

    public void SetAlertHighlight(WpfColor? color)
    {
        if (color is null)
        {
            _surface.Background = new SolidColorBrush(DefaultBackgroundColor);
            _surface.BorderBrush = new SolidColorBrush(DefaultBorderColor);
            return;
        }

        var highlight = color.Value;
        _surface.Background = new SolidColorBrush(WpfColor.FromArgb(246, highlight.R, highlight.G, highlight.B));
        _surface.BorderBrush = new SolidColorBrush(WpfColor.FromArgb(230, 255, 255, 255));
    }

    private void AddChevronGlyph()
    {
        _handleIcon.Children.Add(new System.Windows.Shapes.Path
        {
            Data = Geometry.Parse("M 2,1.5 L 7.5,6 L 13,1.5"),
            Stroke = IconBrush(),
            StrokeThickness = 1.8,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round
        });
    }

    private void AddPocketGlyph()
    {
        var canvas = new Canvas { Width = 15, Height = 8 };
        var dot = new Ellipse
        {
            Width = 2.2,
            Height = 2.2,
            Fill = IconBrush()
        };
        Canvas.SetLeft(dot, 6.4);
        Canvas.SetTop(dot, 0);
        canvas.Children.Add(dot);
        canvas.Children.Add(new System.Windows.Shapes.Path
        {
            Data = Geometry.Parse("M 2.8,3.6 L 2.8,5.4 Q 7.5,8 12.2,5.4 L 12.2,3.6"),
            Stroke = IconBrush(),
            StrokeThickness = 1.5,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round
        });
        _handleIcon.Children.Add(canvas);
    }

    private static SolidColorBrush IconBrush()
    {
        var brush = new SolidColorBrush(WpfColor.FromArgb(184, 255, 255, 255));
        brush.Freeze();
        return brush;
    }
}
