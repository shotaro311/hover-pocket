using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Interop;
using WpfColor = System.Windows.Media.Color;

namespace HoverPocket.Shell.Windows;

internal sealed class AccessSurfaceWindow : NoActivateWindow
{
    public const double ExpandedWidth = 168;
    public const double CompactWidth = 72;
    public const double SurfaceWidth = CompactWidth;
    public const double SurfaceHeight = 9;

    private static readonly WpfColor DefaultBackgroundColor = WpfColor.FromArgb(255, 4, 4, 6);
    private static readonly WpfColor DefaultBorderColor = WpfColor.FromArgb(0, 255, 255, 255);
    private readonly Border _surface;
    private readonly TranslateTransform _peekTransform = new();
    private readonly LiquidSpring _peek = new(1);
    private bool _peekAnimating;
    private long _peekTick;
    private DateTimeOffset? _peekHideAt;

    public bool PeekTargetVisible => _peek.Target == 1;
    public bool IsPeeking => _peekAnimating;
    public bool PeekReady => IsVisible && !_peekAnimating && _peek.Value == 1;
    public event EventHandler? HoverEntered;
    public event Action<bool>? AssetDragChanged;
    public event Action<System.Windows.IDataObject>? AssetDropped;
    public Func<bool>? CanImportAssets { get; set; }

    public AccessSurfaceWindow()
    {
        Width = CompactWidth;
        Height = SurfaceHeight;
        MinWidth = CompactWidth;
        MinHeight = SurfaceHeight;
        MaxWidth = CompactWidth;
        MaxHeight = SurfaceHeight;

        _surface = new Border
        {
            Background = new SolidColorBrush(DefaultBackgroundColor),
            BorderBrush = new SolidColorBrush(DefaultBorderColor),
            BorderThickness = new Thickness(1, 0, 1, 1),
            CornerRadius = new CornerRadius(0, 0, 7, 7),
            SnapsToDevicePixels = true,
            RenderTransform = _peekTransform,
        };
        var root = new Grid { ClipToBounds = true };
        root.Children.Add(_surface);
        Content = root;
        AllowDrop = true;
        DragOver += (_, args) => { args.Effects = CanImportAssets?.Invoke() == true && Providers.Assets.AssetDropPayload.Supports(args.Data) ? System.Windows.DragDropEffects.Copy : System.Windows.DragDropEffects.None; args.Handled = true; if (args.Effects != System.Windows.DragDropEffects.None) AssetDragChanged?.Invoke(true); };
        DragLeave += (_, _) => AssetDragChanged?.Invoke(false);
        Drop += (_, args) => { args.Handled = true; AssetDropped?.Invoke(args.Data); AssetDragChanged?.Invoke(false); };

        MouseEnter += (_, _) => HoverEntered?.Invoke(this, EventArgs.Empty);
    }

    public void UpdatePeekVisibility(bool visible, bool reduceMotion)
    {
        if (visible)
        {
            _peekHideAt = null;
            if (!PeekTargetVisible || !IsVisible || (_peekAnimating && reduceMotion))
                SetPeekVisible(true, reduceMotion);
        }
        else
        {
            _peekHideAt ??= DateTimeOffset.UtcNow.AddMilliseconds(240);
            if (DateTimeOffset.UtcNow >= _peekHideAt && (PeekTargetVisible || IsVisible))
                SetPeekVisible(false, reduceMotion);
        }
    }

    public void SetPeekVisible(bool visible, bool immediate)
    {
        var target = visible ? 1.0 : 0.0;
        if (_peek.Target == target)
        {
            if (_peekAnimating && !immediate) return;
            if (!_peekAnimating && IsVisible == visible && NativeMethods.IsWindowShown(Hwnd) == visible) return;
        }
        _peek.Target = target;
        IsHitTestVisible = false;
        if (visible) ShowNoActivate();
        if (immediate)
        {
            _peek.Snap(target);
            FinishPeek();
        }
        else if (!_peekAnimating)
        {
            _peekAnimating = true;
            _peekTick = Stopwatch.GetTimestamp();
            CompositionTarget.Rendering += RenderPeek;
        }
    }

    private void RenderPeek(object? sender, EventArgs e)
    {
        var elapsed = Stopwatch.GetElapsedTime(_peekTick);
        if (elapsed.TotalMilliseconds < 5) return;
        _peekTick = Stopwatch.GetTimestamp();
        _peek.Step(Math.Min(1.0 / 30, elapsed.TotalSeconds), .16);
        _peekTransform.Y = -SurfaceHeight * (1 - _peek.Value);
        if (_peek.Settled(.005, .03)) FinishPeek();
    }

    private void FinishPeek()
    {
        CompositionTarget.Rendering -= RenderPeek;
        _peekAnimating = false;
        _peek.Snap(_peek.Target);
        _peekTransform.Y = -SurfaceHeight * (1 - _peek.Value);
        IsHitTestVisible = _peek.Target == 1;
        if (_peek.Target == 0)
        {
            Hide();
            NativeMethods.HideWindow(Hwnd);
        }
    }

    protected override void OnClosed(EventArgs e)
    {
        CompositionTarget.Rendering -= RenderPeek;
        _peekAnimating = false;
        base.OnClosed(e);
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
}
