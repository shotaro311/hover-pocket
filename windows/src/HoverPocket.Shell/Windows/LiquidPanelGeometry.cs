using System.Windows;
using System.Windows.Media;
using Point = System.Windows.Point;
using Brushes = System.Windows.Media.Brushes;
using Pen = System.Windows.Media.Pen;

namespace HoverPocket.Shell.Windows;

internal sealed class LiquidSpring(double value)
{
    public double Value { get; private set; } = value;
    public double Velocity { get; private set; }
    public double Target { get; set; } = value;
    public void Step(double seconds, double response)
    {
        var omega = 2 * Math.PI / response;
        var displacement = Value - Target;
        var coefficient = Velocity + omega * displacement;
        var decay = Math.Exp(-omega * Math.Max(0, seconds));
        Value = Target + (displacement + coefficient * seconds) * decay;
        Velocity = (Velocity - omega * coefficient * seconds) * decay;
    }
    public bool Settled(double position = .002, double speed = .02) =>
        Math.Abs(Value - Target) < position && Math.Abs(Velocity) < speed;
    public void Snap(double value) { Value = Target = value; Velocity = 0; }
}

internal sealed record LiquidPanelShape(Geometry Path, double ContentOpacity, double ContentOffset)
{
    public bool Contains(Point point, double tolerance = 0) => Path.FillContains(point)
        || (tolerance > 0 && Path.StrokeContains(new Pen(Brushes.Black, tolerance * 2), point));
}

internal static class LiquidPanelGeometry
{
    public static double SmoothStep(double low, double high, double value)
    {
        var t = Math.Clamp((value - low) / (high - low), 0, 1);
        return t * t * (3 - 2 * t);
    }

    // Mac 661's no-notch meniscus, expressed in Windows DIPs (positive Y downward).
    public static LiquidPanelShape Shape(double progress, double width, double height,
        double originWidth, double contentTop, double attachmentBlend)
    {
        var p = Math.Clamp(progress, 0, 1);
        var blend = Math.Clamp(attachmentBlend, 0, 1);
        var neckWidth = Math.Min(width, originWidth);
        var preserveWidth = neckWidth + (width - neckWidth) * (1 - Math.Pow(1 - p, 1.8));
        var coverWidth = neckWidth + (width - neckWidth) * p;
        var bodyWidth = Mix(preserveWidth, coverWidth, blend);
        var preserveBottom = contentTop + (height - contentTop) * Math.Pow(p, 1.3);
        var coverBottom = contentTop + (height - contentTop) * p;
        var bottom = Mix(preserveBottom, coverBottom, blend);
        var top = Mix(contentTop, Math.Min(contentTop, coverBottom / 2), blend);
        var expandedNeck = Mix(neckWidth, bodyWidth, blend);
        var spread = Math.Max(0, (bodyWidth - expandedNeck) / 2);
        var bodyHeight = Math.Max(0, bottom - top);
        // macOS reserves side padding; the Windows HWND fits the content width.
        var upper = Math.Min(Math.Min(8 * p * blend, top), Math.Max(0, (width - expandedNeck) / 2));
        var join = Math.Min(6 * (1 - blend), Math.Min(spread / 2, Math.Max(0, top - upper)));
        var preserveRadius = Math.Min(18, Math.Min(preserveWidth / 2, Math.Max(0, preserveBottom - contentTop) / 2));
        var lower = Math.Min(Mix(preserveRadius, 10 + 8 * p, blend), Math.Min(bodyWidth / 2, bodyHeight));
        var corner = Math.Min(Math.Max(0, bodyHeight - lower), Math.Min(spread / 2,
            18 * (1 - blend) * SmoothStep(.10, .55, p)));
        var left = (width - expandedNeck) / 2;
        var right = (width + expandedNeck) / 2;
        var x = (width - bodyWidth) / 2;
        var far = x + bodyWidth;
        const double k = .5522847498;
        var geometry = new StreamGeometry();
        using (var c = geometry.Open())
        {
            c.BeginFigure(new Point(left - upper, 0), true, true);
            Line(right + upper, 0);
            Curve(right + upper - k * upper, 0, right, upper - k * upper, right, upper);
            Line(right, top - join);
            Curve(right, top - join + k * join, right + join - k * join, top, right + join, top);
            Line(far - corner, top);
            Curve(far - corner + k * corner, top, far, top + corner - k * corner, far, top + corner);
            Line(far, bottom - lower);
            Curve(far, bottom - lower + k * lower, far - lower + k * lower, bottom, far - lower, bottom);
            Line(x + lower, bottom);
            Curve(x + lower - k * lower, bottom, x, bottom - lower + k * lower, x, bottom - lower);
            Line(x, top + corner);
            Curve(x, top + corner - k * corner, x + corner - k * corner, top, x + corner, top);
            Line(left - join, top);
            Curve(left - join + k * join, top, left, top - join + k * join, left, top - join);
            Line(left, upper);
            Curve(left, upper - k * upper, left - upper + k * upper, 0, left - upper, 0);
            void Line(double a, double b) => c.LineTo(new Point(a, b), true, false);
            void Curve(double a, double b, double d, double e, double f, double g) =>
                c.BezierTo(new Point(a, b), new Point(d, e), new Point(f, g), true, false);
        }
        geometry.Freeze();
        var opacity = SmoothStep(.38, .88, p);
        return new LiquidPanelShape(geometry, opacity, -10 * (1 - opacity) * (1 - blend));
    }
    private static double Mix(double a, double b, double t) => a + (b - a) * t;
}
