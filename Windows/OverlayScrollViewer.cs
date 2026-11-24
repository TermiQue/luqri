using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace Luqri;

public sealed class OverlayScrollViewer : ScrollViewer
{
    private static readonly DependencyPropertyKey IsScrollIndicatorVisiblePropertyKey =
        DependencyProperty.RegisterReadOnly(nameof(IsScrollIndicatorVisible), typeof(bool),
            typeof(OverlayScrollViewer), new PropertyMetadata(false));

    public static readonly DependencyProperty IsScrollIndicatorVisibleProperty =
        IsScrollIndicatorVisiblePropertyKey.DependencyProperty;

    public bool IsScrollIndicatorVisible => (bool)GetValue(IsScrollIndicatorVisibleProperty);

    private readonly DispatcherTimer hideTimer;

    public OverlayScrollViewer()
    {
        hideTimer = new DispatcherTimer(DispatcherPriority.Background, Dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(650)
        };
        hideTimer.Tick += (_, _) =>
        {
            if (GetTemplateChild("PART_VerticalScrollBar") is not UIElement { IsMouseCaptureWithin: true })
                HideIndicator();
        };
        Unloaded += (_, _) => HideIndicator();
    }

    protected override void OnScrollChanged(ScrollChangedEventArgs e)
    {
        base.OnScrollChanged(e);
        if (e.VerticalChange == 0 || ScrollableHeight <= 0 || !IsVisible) return;

        SetValue(IsScrollIndicatorVisiblePropertyKey, true);
        hideTimer.Stop();
        hideTimer.Start();
    }

    private void HideIndicator()
    {
        hideTimer.Stop();
        SetValue(IsScrollIndicatorVisiblePropertyKey, false);
    }
}
