using System.Buffers;
using System.Buffers.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Luqri;

internal static class OcrImage
{
    internal const int MaximumDimension = 2048;
    private const int MinimumDimension = 256;
    private const int MaximumFormBytes = 8_000_000;
    private const int MaximumAliyunBytes = 10_000_000;
    private static readonly int[] JpegQualities = [90, 72, 55];
    private static readonly SearchValues<byte> EscapedBytes = SearchValues.Create("+/="u8);

    internal static (int Width, int Height) Fit(int width, int height, int maximum = MaximumDimension)
    {
        var scale = Math.Min(1.0, (double)maximum / Math.Max(width, height));
        return (Math.Max(1, (int)Math.Round(width * scale)), Math.Max(1, (int)Math.Round(height * scale)));
    }

    internal static byte[] Encode(BitmapSource image, CancellationToken token) => Encode(image, true, token);

    internal static byte[] EncodeAliyun(BitmapSource image, CancellationToken token) => Encode(image, false, token);

    private static byte[] Encode(BitmapSource image, bool form, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var frame = BitmapFrame.Create(Prepare(image));
        using var jpeg = new MemoryStream();
        foreach (var quality in JpegQualities)
        {
            token.ThrowIfCancellationRequested();
            jpeg.SetLength(0);
            var encoder = new JpegBitmapEncoder { QualityLevel = quality };
            encoder.Frames.Add(frame);
            encoder.Save(jpeg);
            if (!form && jpeg.Length <= MaximumAliyunBytes) return jpeg.ToArray();
            if (form && Form(jpeg.GetBuffer().AsSpan(0, (int)jpeg.Length)) is { } payload) return payload;
        }
        throw new InvalidOperationException("截图超过 OCR 的大小限制，请缩小选区。");
    }

    private static BitmapSource Prepare(BitmapSource image)
    {
        var (scaledWidth, scaledHeight) = Fit(image.PixelWidth, image.PixelHeight);
        var width = Math.Max(MinimumDimension, scaledWidth);
        var height = Math.Max(MinimumDimension, scaledHeight);
        if (width == image.PixelWidth && height == image.PixelHeight && image.Format == PixelFormats.Bgr32)
            return image;

        var visual = new DrawingVisual();
        RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.HighQuality);
        using (var drawing = visual.RenderOpen())
        {
            drawing.DrawRectangle(Brushes.White, null, new Rect(0, 0, width, height));
            drawing.DrawImage(image, new Rect((width - scaledWidth) / 2, (height - scaledHeight) / 2, scaledWidth, scaledHeight));
        }
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        return bitmap;
    }

    internal static byte[]? Form(ReadOnlySpan<byte> jpeg)
    {
        var prefix = "image_base64="u8;
        var base64Length = Base64.GetMaxEncodedToUtf8Length(jpeg.Length);
        if (prefix.Length + base64Length > MaximumFormBytes) return null;

        // Base64 is ASCII. In the form value only '+', '/' and '=' need escaping.
        var buffer = ArrayPool<byte>.Shared.Rent(base64Length);
        try
        {
            Base64.EncodeToUtf8(jpeg, buffer, out _, out var written);
            var encoded = buffer.AsSpan(0, written);
            var escapedLength = written + 2 * (encoded.Count((byte)'+') + encoded.Count((byte)'/') + encoded.Count((byte)'='));
            if (prefix.Length + escapedLength > MaximumFormBytes) return null;

            var payload = GC.AllocateUninitializedArray<byte>(prefix.Length + escapedLength);
            prefix.CopyTo(payload);
            var destination = payload.AsSpan(prefix.Length);
            for (var index = encoded.IndexOfAny(EscapedBytes); index >= 0; index = encoded.IndexOfAny(EscapedBytes))
            {
                encoded[..index].CopyTo(destination);
                var escape = encoded[index] switch
                {
                    (byte)'+' => "%2B"u8,
                    (byte)'/' => "%2F"u8,
                    _ => "%3D"u8
                };
                escape.CopyTo(destination[index..]);
                destination = destination[(index + escape.Length)..];
                encoded = encoded[(index + 1)..];
            }
            encoded.CopyTo(destination);
            return payload;
        }
        finally
        {
            // The pooled buffer contains part of the user's screenshot.
            ArrayPool<byte>.Shared.Return(buffer, clearArray: true);
        }
    }
}
