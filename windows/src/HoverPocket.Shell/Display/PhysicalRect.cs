using HoverPocket.Shell.Interop;

namespace HoverPocket.Shell.Display;

internal readonly record struct PhysicalRect(int Left, int Top, int Width, int Height)
{
    public int Right => Left + Width;
    public int Bottom => Top + Height;

    public static PhysicalRect FromNative(NativeRect rect)
    {
        return new PhysicalRect(rect.Left, rect.Top, rect.Width, rect.Height);
    }

    public bool Contains(int x, int y)
    {
        return x >= Left && x <= Right && y >= Top && y <= Bottom;
    }

    public bool Contains(PhysicalRect rect)
    {
        return rect.Left >= Left
            && rect.Top >= Top
            && rect.Right <= Right
            && rect.Bottom <= Bottom;
    }

    public PhysicalRect ClampTo(PhysicalRect bounds)
    {
        var width = Math.Min(Width, bounds.Width);
        var height = Math.Min(Height, bounds.Height);
        var left = Math.Clamp(Left, bounds.Left, bounds.Right - width);
        var top = Math.Clamp(Top, bounds.Top, bounds.Bottom - height);

        return new PhysicalRect(left, top, width, height);
    }
}
