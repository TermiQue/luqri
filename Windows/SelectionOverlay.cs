using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Drawing = System.Drawing;

namespace Luqri;

internal sealed class SelectionOverlay : Window
{
    private readonly Grid surface = new() { Background = Brushes.Transparent, ClipToBounds = true };
    private readonly SelectionShade shade = new() { IsHitTestVisible = false };
    private readonly Border? hint;
    private readonly Action<ScreenCapture.Region?> finish;
    private Point? start;

    public Drawing.Rectangle Bounds { get; }

    public SelectionOverlay(Drawing.Rectangle bounds, bool hasHint, Action<ScreenCapture.Region?> finish)
    {
        Bounds = bounds;
        this.finish = finish;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Cursor = Cursors.Cross;
        Content = surface;
        surface.Children.Add(shade);
        if (hasHint)
        {
            hint = new Border
            {
                Background = Brushes.White, CornerRadius = new(7), Padding = new(14, 8, 14, 8),
                Margin = new(0, 54, 0, 0), HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false,
                Child = new TextBlock { Text = "拖动框选文字   ·   Esc 取消", Foreground = Brushes.Black, FontSize = 13 }
            };
            surface.Children.Add(hint);
        }
        surface.SizeChanged += (_, _) => Refresh(ClampedPointer(Mouse.GetPosition(surface)));
        surface.MouseLeftButtonDown += (_, e) =>
        {
            Activate();
            start = ClampedPointer(e.GetPosition(surface));
            surface.CaptureMouse();
            Refresh(start.Value);
        };
        surface.MouseMove += (_, e) => Refresh(ClampedPointer(e.GetPosition(surface)));
        surface.MouseLeftButtonUp += (_, e) => Complete(ClampedPointer(e.GetPosition(surface)));
        surface.LostMouseCapture += (_, _) =>
        {
            if (start is null) return;
            start = null;
            Refresh(ClampedPointer(Mouse.GetPosition(surface)));
        };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { e.Handled = true; finish(null); }
        };
        MouseRightButtonDown += (_, _) => finish(null);
    }

    private Point ClampedPointer(Point point) =>
        new(Math.Clamp(point.X, 0, surface.ActualWidth), Math.Clamp(point.Y, 0, surface.ActualHeight));

    private void Complete(Point end)
    {
        if (start is not { } origin) return;
        var selection = new Rect(origin, end);
        start = null;
        surface.ReleaseMouseCapture();
        if (selection.Width < 4 || selection.Height < 4)
        {
            Refresh(end);
            return;
        }

        var first = surface.PointToScreen(selection.TopLeft);
        var last = surface.PointToScreen(selection.BottomRight);
        var cursor = surface.PointToScreen(end);
        var bounds = Drawing.Rectangle.FromLTRB((int)Math.Floor(first.X), (int)Math.Floor(first.Y),
            (int)Math.Ceiling(last.X), (int)Math.Ceiling(last.Y));
        bounds = Drawing.Rectangle.Intersect(Bounds, bounds);
        if (bounds.Width > 0 && bounds.Height > 0)
            finish(new(bounds, new((int)cursor.X, (int)cursor.Y)));
        else
            Refresh(end);
    }

    private void Refresh(Point pointer)
    {
        shade.SetSelection(start is { } origin ? new Rect(origin, pointer) : Rect.Empty);
        if (hint is null) return;
        if (start is not null)
        {
            hint.Visibility = Visibility.Hidden;
            return;
        }
        var hintBounds = new Rect(hint.TranslatePoint(default, surface), hint.RenderSize);
        hintBounds.Inflate(10, 10);
        hint.Visibility = !hintBounds.Contains(pointer) ? Visibility.Visible : Visibility.Hidden;
    }
}

internal sealed class SelectionShade : FrameworkElement
{
    private static readonly Brush Shade = CreateShade();
    private static readonly Pen Outline = CreateOutline();
    private Rect selection = Rect.Empty;

    internal void SetSelection(Rect bounds)
    {
        if (selection == bounds) return;
        selection = bounds;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext drawing)
    {
        var full = new Rect(RenderSize);
        var cutout = Rect.Intersect(full, selection);
        if (cutout.IsEmpty || cutout.Width == 0 || cutout.Height == 0)
        {
            drawing.DrawRectangle(Shade, null, full);
            return;
        }

        drawing.DrawRectangle(Shade, null, new Rect(0, 0, full.Width, cutout.Top));
        drawing.DrawRectangle(Shade, null, new Rect(0, cutout.Bottom, full.Width, full.Bottom - cutout.Bottom));
        drawing.DrawRectangle(Shade, null, new Rect(0, cutout.Top, cutout.Left, cutout.Height));
        drawing.DrawRectangle(Shade, null, new Rect(cutout.Right, cutout.Top, full.Right - cutout.Right, cutout.Height));
        drawing.DrawRectangle(null, Outline, cutout);
    }

    private static Brush CreateShade()
    {
        var brush = new SolidColorBrush(Color.FromArgb(74, 0, 0, 0));
        brush.Freeze();
        return brush;
    }

    private static Pen CreateOutline()
    {
        var pen = new Pen(Brushes.White, 1);
        pen.Freeze();
        return pen;
    }
}
