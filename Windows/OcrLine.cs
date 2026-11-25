using System.Text;
using System.Windows;

namespace Luqri;

internal sealed record OcrLine(string Text, Rect Bounds)
{
    public static string Paragraphs(IEnumerable<OcrLine> lines)
    {
        var result = new StringBuilder();
        OcrLine? previous = null;
        foreach (var line in lines)
        {
            if (previous is not null) result.Append(Separator(previous, line));
            result.Append(line.Text);
            previous = line;
        }
        return result.ToString();
    }

    private static string Separator(OcrLine previous, OcrLine next)
    {
        var first = previous.Bounds;
        var second = next.Bounds;
        if (first.IsEmpty || second.IsEmpty) return "\n";
        var height = Math.Max(first.Height, second.Height);
        if (height <= 0) return "\n";
        var advance = second.Y + second.Height / 2 - first.Y - first.Height / 2;
        if (advance < -height * 0.5 || second.Top - first.Bottom > height * 0.9) return "\n\n";
        var continuesLine = advance > height * 0.55 && advance < height * 1.85 &&
            first.Width >= height * 5 && first.Right >= second.Right - height * 0.6 &&
            Math.Min(first.Height, second.Height) >= height * 0.75;
        if (!continuesLine || Math.Abs(second.Left - first.Left) >= height * 0.45 ||
            IsListItem(previous.Text) || IsListItem(next.Text) || ":：".Contains(previous.Text[^1])) return "\n";

        Rune.DecodeLastFromUtf16(previous.Text, out var lastText, out _);
        Rune.DecodeFromUtf16(next.Text, out var firstText, out _);
        return (IsEastAsian(lastText.Value) && IsEastAsian(firstText.Value)) ||
            "，。！？、；：）】》」』".Contains(next.Text[0]) ? "" : " ";
    }

    private static bool IsListItem(string text) => text.StartsWith('•') || text.StartsWith('・') ||
        text.StartsWith("- ", StringComparison.Ordinal) ||
        (char.IsNumber(text[0]) && text.Take(5).Any(ch => ".、)）".Contains(ch)));

    private static bool IsEastAsian(int value) =>
        value is >= 0x3000 and <= 0x30ff or >= 0x3400 and <= 0x9fff or
            >= 0xf900 and <= 0xfaff or >= 0x20000 and <= 0x323af;
}
