using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace Luqri;

internal sealed class ScreenCapture
{
    private readonly List<SelectionOverlay> windows = new();
    private TaskCompletionSource<Region?>? pending;
    private nint previousWindow;

    public sealed record Region(Drawing.Rectangle Bounds, Drawing.Point Anchor);

    public Task<Region?> SelectAsync()
    {
        Cancel();
        previousWindow = Native.GetForegroundWindow();
        var cursor = Forms.Cursor.Position;
        var completion = new TaskCompletionSource<Region?>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending = completion;
        try
        {
            foreach (var screen in Forms.Screen.AllScreens)
            {
                var overlay = new SelectionOverlay(screen.Bounds, screen.Bounds.Contains(cursor), Finish);
                windows.Add(overlay);
                Native.FitOverlay(overlay, screen.Bounds);
                overlay.Show();
            }
            var active = windows.FirstOrDefault(window => window.Bounds.Contains(cursor)) ?? windows.FirstOrDefault();
            if (active is null) Cancel();
            else active.Activate();
            return completion.Task;
        }
        catch
        {
            Cancel();
            throw;
        }
    }

    public static BitmapSource Capture(Region region)
    {
        Native.DwmFlush();
        using var bitmap = new Drawing.Bitmap(region.Bounds.Width, region.Bounds.Height, Drawing.Imaging.PixelFormat.Format32bppRgb);
        using (var graphics = Drawing.Graphics.FromImage(bitmap))
        {
            var screen = Native.GetDC(0);
            if (screen == 0) throw new InvalidOperationException("无法读取屏幕，请重新框选。");
            try
            {
                var target = graphics.GetHdc();
                try
                {
                    const uint copyLayeredWindows = 0x40CC0020; // SRCCOPY | CAPTUREBLT
                    if (!Native.BitBlt(target, 0, 0, region.Bounds.Width, region.Bounds.Height,
                        screen, region.Bounds.X, region.Bounds.Y, copyLayeredWindows))
                        throw new InvalidOperationException("无法截取选区，请重新框选。");
                }
                finally { graphics.ReleaseHdc(target); }
            }
            finally { Native.ReleaseDC(0, screen); }
        }

        var handle = bitmap.GetHbitmap();
        try
        {
            var source = Imaging.CreateBitmapSourceFromHBitmap(handle, 0, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            var pixels = new FormatConvertedBitmap(source, PixelFormats.Bgr32, null, 0);
            pixels.Freeze();
            return pixels;
        }
        finally { Native.DeleteObject(handle); }
    }

    public void Cancel() => Finish(null);

    private void Finish(Region? region)
    {
        var completion = pending;
        if (completion is null) return;
        pending = null;
        var hadFocus = windows.Any(window => window.IsActive);
        foreach (var window in windows) window.Close();
        windows.Clear();
        if (hadFocus && previousWindow != 0) Native.SetForegroundWindow(previousWindow);
        completion.TrySetResult(region);
    }
}

internal sealed class SelectionOverlay : Window
{
    private readonly Canvas canvas = new() { Background = Brushes.Transparent, ClipToBounds = true };
    private readonly System.Windows.Shapes.Path shade = new()
    {
        Fill = new SolidColorBrush(Color.FromArgb(74, 0, 0, 0)), IsHitTestVisible = false
    };
    private readonly Border outline = new() { BorderBrush = Brushes.White, BorderThickness = new(1), IsHitTestVisible = false };
    private readonly Border hint = new()
    {
        Background = Brushes.White, CornerRadius = new(7), Padding = new(14, 8, 14, 8), IsHitTestVisible = false,
        Child = new TextBlock { Text = "拖动框选文字   ·   Esc 取消", Foreground = Brushes.Black, FontSize = 13 }
    };
    private readonly bool hasHint;
    private readonly Action<ScreenCapture.Region?> finish;
    private Point? start;

    public Drawing.Rectangle Bounds { get; }

    public SelectionOverlay(Drawing.Rectangle bounds, bool hasHint, Action<ScreenCapture.Region?> finish)
    {
        Bounds = bounds;
        this.hasHint = hasHint;
        this.finish = finish;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Cursor = Cursors.Cross;
        Content = canvas;
        canvas.Children.Add(shade);
        canvas.Children.Add(outline);
        if (hasHint) canvas.Children.Add(hint);
        canvas.SizeChanged += (_, _) => Draw(null, Mouse.GetPosition(canvas));
        canvas.MouseLeftButtonDown += (_, e) =>
        {
            Activate();
            start = Clamp(e.GetPosition(canvas));
            canvas.CaptureMouse();
            Draw(null, start.Value);
        };
        canvas.MouseMove += (_, e) =>
        {
            var point = Clamp(e.GetPosition(canvas));
            Draw(start is { } origin ? new Rect(origin, point) : null, point);
        };
        canvas.MouseLeftButtonUp += (_, e) => Complete(Clamp(e.GetPosition(canvas)));
        canvas.LostMouseCapture += (_, _) =>
        {
            if (start is null) return;
            start = null;
            Draw(null, Mouse.GetPosition(canvas));
        };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { e.Handled = true; finish(null); }
        };
        MouseRightButtonDown += (_, _) => finish(null);
    }

    private Point Clamp(Point point) => new(Math.Clamp(point.X, 0, canvas.ActualWidth), Math.Clamp(point.Y, 0, canvas.ActualHeight));

    private void Complete(Point end)
    {
        if (start is not { } origin) return;
        var selection = new Rect(origin, end);
        start = null;
        canvas.ReleaseMouseCapture();
        if (selection.Width < 4 || selection.Height < 4)
        {
            Draw(null, end);
            return;
        }

        var first = canvas.PointToScreen(selection.TopLeft);
        var last = canvas.PointToScreen(selection.BottomRight);
        var cursor = canvas.PointToScreen(end);
        var bounds = Drawing.Rectangle.FromLTRB((int)Math.Floor(first.X), (int)Math.Floor(first.Y),
            (int)Math.Ceiling(last.X), (int)Math.Ceiling(last.Y));
        finish(new(Drawing.Rectangle.Intersect(Bounds, bounds), new((int)cursor.X, (int)cursor.Y)));
    }

    private void Draw(Rect? selection, Point pointer)
    {
        var full = new RectangleGeometry(new Rect(0, 0, canvas.ActualWidth, canvas.ActualHeight));
        outline.Visibility = selection.HasValue ? Visibility.Visible : Visibility.Collapsed;
        shade.Data = full;
        if (selection is { } box)
        {
            shade.Data = new CombinedGeometry(GeometryCombineMode.Exclude, full, new RectangleGeometry(box));
            Canvas.SetLeft(outline, box.Left);
            Canvas.SetTop(outline, box.Top);
            outline.Width = box.Width;
            outline.Height = box.Height;
        }
        if (!hasHint) return;
        hint.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var hintPosition = new Rect((canvas.ActualWidth - hint.DesiredSize.Width) / 2, 54,
            hint.DesiredSize.Width, hint.DesiredSize.Height);
        Canvas.SetLeft(hint, hintPosition.Left);
        Canvas.SetTop(hint, hintPosition.Top);
        hintPosition.Inflate(10, 10);
        hint.Visibility = start is null && !hintPosition.Contains(pointer) ? Visibility.Visible : Visibility.Hidden;
    }
}
