using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Xml.Linq;

namespace Luqri;

public sealed class Icon : Shape
{
    private static readonly Dictionary<string, Geometry> Icons = new();
    public static readonly DependencyProperty GlyphProperty = DependencyProperty.Register(nameof(Glyph), typeof(string),
        typeof(Icon), new FrameworkPropertyMetadata("", FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));

    public string Glyph
    {
        get => (string)GetValue(GlyphProperty);
        set => SetValue(GlyphProperty, value);
    }

    protected override Geometry DefiningGeometry => Glyph.Length == 0 ? Geometry.Empty : DrawingFor(Glyph);

    internal static Geometry DrawingFor(string glyph)
    {
        if (Icons.TryGetValue(glyph, out var cached)) return cached;
        var resource = Application.GetResourceStream(new Uri($"Icons/{glyph}.svg", UriKind.Relative));
        using var stream = resource.Stream;
        var svg = XElement.Load(stream);
        var drawing = new GeometryGroup();
        foreach (var part in svg.Elements())
        {
            double Number(string name) => double.Parse((string?)part.Attribute(name) ?? "0", CultureInfo.InvariantCulture);
            var geometry = part.Name.LocalName switch
            {
                "path" => Geometry.Parse((string)part.Attribute("d")!),
                "circle" => new EllipseGeometry(new Point(Number("cx"), Number("cy")), Number("r"), Number("r")),
                "rect" => new RectangleGeometry(new Rect(Number("x"), Number("y"), Number("width"), Number("height")),
                    Number("rx"), part.Attribute("ry") is null ? Number("rx") : Number("ry")),
                _ => Geometry.Empty
            };
            drawing.Children.Add(geometry);
        }
        // Preserve the original SVG view box without rendering any extra marks.
        drawing.Children.Add(new PathGeometry([
            new PathFigure(new Point(0, 0), [new LineSegment(new Point(24, 24), false)], false) { IsFilled = false }
        ]));
        drawing.Freeze();
        return Icons[glyph] = drawing;
    }
}
