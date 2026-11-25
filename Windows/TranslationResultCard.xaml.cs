using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace Luqri;

public partial class TranslationResultCard : UserControl
{
    private bool expanded = true;

    internal event Action<TranslationResultCard>? Collapsed;
    internal event Action<TranslationResultCard>? CopyRequested;
    internal event Action<TranslationResultCard>? SpeakRequested;

    internal TranslationResultCard(CloudProvider provider)
    {
        InitializeComponent();
        ServiceName.Text = CloudServices.Name(provider);
        ServiceIcon.Glyph = provider == CloudProvider.Aliyun ? "languages" : "flame";
        AutomationProperties.SetName(ServiceHeader, ServiceName.Text);
        Reset();
    }

    internal void Reset()
    {
        Result.Text = "";
        ResultCopyIcon.Glyph = "copy";
        ResultStatus.Text = "按 Ctrl+Enter 翻译";
    }

    internal void BeginTranslation()
    {
        expanded = true;
        ResultStatus.Text = "正在翻译…";
    }

    internal void UpdateLayoutState(bool hasText)
    {
        ServiceHeader.IsEnabled = hasText;
        ResultPanel.Visibility = expanded && hasText ? Visibility.Visible : Visibility.Collapsed;
        Chevron.Glyph = ResultPanel.Visibility == Visibility.Visible ? "chevron-down" : "chevron-right";
        var hasResult = Result.Text.Length != 0;
        ResultStatus.Visibility = hasResult ? Visibility.Collapsed : Visibility.Visible;
        Result.Visibility = ResultActions.Visibility = hasResult ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ToggleResult(object sender, RoutedEventArgs e)
    {
        expanded = !expanded;
        if (!expanded) Collapsed?.Invoke(this);
        UpdateLayoutState(ServiceHeader.IsEnabled);
    }

    private void CopyResult(object sender, RoutedEventArgs e) => CopyRequested?.Invoke(this);
    private void SpeakResult(object sender, RoutedEventArgs e) => SpeakRequested?.Invoke(this);
}
