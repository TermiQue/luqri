using System.Runtime.InteropServices;
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

    public static BitmapSource Capture(Region region, int maximumDimension = OcrImage.MaximumDimension)
    {
        Native.DwmFlush();
        var bounds = region.Bounds;
        var (width, height) = OcrImage.Fit(bounds.Width, bounds.Height, maximumDimension);
        var screen = GetDC(0);
        if (screen == 0) throw new InvalidOperationException("无法读取屏幕，请重新框选。");
        try
        {
            var capture = CopyRegion(screen, bounds, width, height);
            if (capture is not null) return capture;
            // Fall back to an unscaled read on display drivers that cannot stretch a screen region.
            if ((width, height) != (bounds.Width, bounds.Height) &&
                CopyRegion(screen, bounds, bounds.Width, bounds.Height) is { } fullSize) return fullSize;
            throw new InvalidOperationException("无法截取选区，请重新框选。");
        }
        finally { ReleaseDC(0, screen); }
    }

    private static BitmapSource? CopyRegion(nint screen, Drawing.Rectangle bounds, int width, int height)
    {
        var target = CreateCompatibleDC(screen);
        if (target == 0) return null;
        nint bitmap = 0;
        nint previous = 0;
        try
        {
            var info = new BitmapInfoHeader
            {
                Size = (uint)Marshal.SizeOf<BitmapInfoHeader>(), Width = width, Height = -height, Planes = 1, BitsPerPixel = 32
            };
            bitmap = CreateDIBSection(target, ref info, 0, out var buffer, 0, 0);
            if (bitmap == 0 || buffer == 0) return null;
            previous = SelectObject(target, bitmap);
            if (previous == 0 || previous == -1 || !CopyPixels(target, screen, bounds, width, height) || !GdiFlush())
                return null;

            var stride = checked(width * 4);
            var pixels = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgr32, null, buffer, checked(stride * height), stride);
            pixels.Freeze();
            return pixels;
        }
        finally
        {
            if (previous != 0 && previous != -1) SelectObject(target, previous);
            DeleteDC(target);
            if (bitmap != 0) DeleteObject(bitmap);
        }
    }

    private static bool CopyPixels(nint target, nint screen, Drawing.Rectangle bounds, int width, int height)
    {
        const uint copyLayeredWindows = 0x40CC0020; // SRCCOPY | CAPTUREBLT
        if (width == bounds.Width && height == bounds.Height)
            return BitBlt(target, 0, 0, width, height, screen, bounds.X, bounds.Y, copyLayeredWindows);

        const int halftone = 4;
        return SetStretchBltMode(target, halftone) != 0 && SetBrushOrgEx(target, 0, 0, 0) &&
            StretchBlt(target, 0, 0, width, height, screen, bounds.X, bounds.Y, bounds.Width, bounds.Height, copyLayeredWindows);
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

    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapInfoHeader
    {
        public uint Size;
        public int Width, Height;
        public ushort Planes, BitsPerPixel;
        public uint Compression, SizeImage;
        public int XPixelsPerMeter, YPixelsPerMeter;
        public uint ColorsUsed, ColorsImportant;
    }

    [DllImport("user32")] private static extern nint GetDC(nint window);
    [DllImport("user32")] private static extern int ReleaseDC(nint window, nint dc);
    [DllImport("gdi32")] private static extern nint CreateCompatibleDC(nint dc);
    [DllImport("gdi32")] private static extern bool DeleteDC(nint dc);
    [DllImport("gdi32")] private static extern bool DeleteObject(nint handle);
    [DllImport("gdi32")] private static extern nint SelectObject(nint dc, nint handle);
    [DllImport("gdi32")] private static extern nint CreateDIBSection(nint dc, ref BitmapInfoHeader info, uint usage,
        out nint buffer, nint section, uint offset);
    [DllImport("gdi32")] private static extern bool GdiFlush();
    [DllImport("gdi32")] private static extern int SetStretchBltMode(nint dc, int mode);
    [DllImport("gdi32")] private static extern bool SetBrushOrgEx(nint dc, int x, int y, nint previous);
    [DllImport("gdi32")] private static extern bool BitBlt(nint target, int x, int y, int width, int height,
        nint source, int sourceX, int sourceY, uint operation);
    [DllImport("gdi32")] private static extern bool StretchBlt(nint target, int x, int y, int width, int height,
        nint source, int sourceX, int sourceY, int sourceWidth, int sourceHeight, uint operation);
}
