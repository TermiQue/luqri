using System.Runtime.InteropServices;
using System.Speech.Synthesis;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Luqri;

public partial class TranslationWindow : Window
{
    private readonly Preferences preferences;
    private readonly CloudServices cloud;
    private readonly Action openSettings;
    private readonly Dictionary<CloudProvider, TranslationResultCard> results = new();
    private CancellationTokenSource? work;
    private SpeechSynthesizer? speech;
    private TranslationResultCard? speakingResult;
    private bool pinned;
    private bool loadingInput;
    private bool initialized;
    private TranslationLanguage? resultLanguage;
    private string? inputError;

    internal TranslationWindow(Preferences preferences, CloudServices cloud, Action openSettings)
    {
        this.preferences = preferences;
        this.cloud = cloud;
        this.openSettings = openSettings;
        InitializeComponent();
        foreach (var provider in CloudServices.Providers)
        {
            var card = new TranslationResultCard(provider);
            card.Collapsed += result => { if (speakingResult == result) StopSpeech(); };
            card.CopyRequested += result => Copy(result.Result.Text, result.ResultCopyIcon);
            card.SpeakRequested += result => Speak(result.Result.Text, resultLanguage, result);
            results.Add(provider, card);
            ServiceCards.Children.Add(card);
        }
        initialized = true;
        Loaded += (_, _) => Editor.Focus();
        UpdateControls();
    }

    internal void PreferencesChanged()
    {
        if (!loadingInput) CancelWork();
        ClearResult();
        StopSpeech();
        UpdateControls();
    }

    internal async Task LoadAsync(string? text, BitmapSource? image, CloudProvider ocrProvider)
    {
        if (image is not null)
        {
            CancelWork();
            var current = work = new CancellationTokenSource();
            loadingInput = true;
            inputError = null;
            UpdateControls();
            try { text = await cloud[ocrProvider].RecognizeAsync(image, Preferences.RequireCredentials(ocrProvider), current.Token); }
            catch (OperationCanceledException) when (current.IsCancellationRequested) { return; }
            catch (Exception error)
            {
                if (current.IsCancellationRequested) return;
                inputError = CloudServices.DescribeError(ocrProvider, error);
            }
            finally
            {
                if (work == current)
                {
                    work = null;
                    loadingInput = false;
                    UpdateControls();
                }
                current.Dispose();
            }
            if (!IsVisible) return;
        }
        if (string.IsNullOrWhiteSpace(text)) return;
        Editor.Text = text;
        Editor.CaretIndex = Editor.Text.Length;
        await TranslateAsync();
    }

    private async Task TranslateAsync()
    {
        var input = Editor.Text.Trim();
        if (input.Length == 0 || loadingInput || work is not null) return;
        var providers = CloudServices.Providers.Where(preferences.UsesTranslation).ToArray();
        if (providers.Length == 0) return;

        ClearResult();
        StopSpeech();
        SetNotice(null);
        var current = work = new CancellationTokenSource();
        var source = TranslationLanguage.Find(preferences.Source);
        var target = TranslationLanguage.Find(preferences.Target) ?? TranslationLanguage.TargetFor(input, source);
        resultLanguage = target;
        foreach (var provider in providers) results[provider].BeginTranslation();
        UpdateControls();
        try
        {
            await Task.WhenAll(providers.Select(TranslateProviderAsync));
        }
        finally
        {
            if (work == current)
            {
                work = null;
                UpdateControls();
            }
            current.Dispose();
        }

        async Task TranslateProviderAsync(CloudProvider provider)
        {
            var card = results[provider];
            try
            {
                var translated = await cloud[provider].TranslateAsync(input, source, target, Preferences.RequireCredentials(provider), current.Token);
                if (!current.IsCancellationRequested) card.Result.Text = translated;
            }
            catch (OperationCanceledException) when (current.IsCancellationRequested) { }
            catch (Exception error)
            {
                if (!current.IsCancellationRequested) card.ResultStatus.Text = CloudServices.DescribeError(provider, error);
            }
            if (!current.IsCancellationRequested) card.UpdateLayoutState(hasText: true);
        }
    }

    private void CancelWork()
    {
        var pending = work;
        work = null;
        loadingInput = false;
        pending?.Cancel();
    }

    private void ClearResult()
    {
        resultLanguage = null;
        foreach (var card in results.Values) card.Reset();
    }

    private void OnEdited(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        if (!initialized) return;
        CancelWork();
        inputError = null;
        StopSpeech();
        ClearResult();
        SourceCopyIcon.Glyph = "copy";
        SetNotice(null);
        UpdateControls();
    }

    private void UpdateControls()
    {
        var hasText = !string.IsNullOrWhiteSpace(Editor.Text);
        var hasProvider = CloudServices.Providers.Any(preferences.UsesTranslation);
        Editor.IsReadOnly = loadingInput;
        Placeholder.Visibility = Editor.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Placeholder.Text = loadingInput ? "正在识别文字…" : inputError ?? "输入或粘贴文字…";
        SourceSpeak.IsEnabled = SourceCopy.IsEnabled = hasText;
        TranslateButton.IsEnabled = hasText && !loadingInput && work is null && hasProvider;
        PasteButton.IsEnabled = !loadingInput;
        DisabledCard.Visibility = hasProvider ? Visibility.Collapsed : Visibility.Visible;
        foreach (var (provider, card) in results)
        {
            card.Visibility = preferences.UsesTranslation(provider) ? Visibility.Visible : Visibility.Collapsed;
            card.UpdateLayoutState(hasText);
        }
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        var modifiers = Keyboard.Modifiers;
        if (e.Key == Key.Escape || (modifiers == ModifierKeys.Control && e.Key == Key.W))
        {
            e.Handled = true;
            Close();
        }
        else if ((modifiers == ModifierKeys.Control && e.Key == Key.OemComma))
        {
            e.Handled = true;
            openSettings();
        }
        else if (modifiers == ModifierKeys.Control && e.Key == Key.H)
        {
            e.Handled = true;
            ((App)Application.Current).HideWindows();
        }
        else if (modifiers == ModifierKeys.Control && e.Key == Key.Q)
        {
            e.Handled = true;
            Application.Current.Shutdown();
        }
        else if (e.Key == Key.Enter && (modifiers == ModifierKeys.Control ||
            (modifiers == ModifierKeys.None && Editor.IsKeyboardFocused && !string.IsNullOrWhiteSpace(Editor.Text))))
        {
            e.Handled = true;
            _ = TranslateAsync();
        }
    }

    private void TogglePin(object sender, RoutedEventArgs e)
    {
        pinned = !pinned;
        var label = pinned ? "取消置顶" : "置顶浮窗";
        PinButton.ToolTip = label;
        System.Windows.Automation.AutomationProperties.SetName(PinButton, label);
        PinIcon.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty, pinned ? "Accent" : "Ink");
    }

    private void OnDeactivated(object? sender, EventArgs e)
    {
        if (pinned) return;
        Dispatcher.BeginInvoke(DispatcherPriority.Normal, () =>
        {
            if (IsVisible && !IsActive && !pinned) Close();
        });
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        CancelWork();
        StopSpeech();
    }

    private void DragHeader(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed) DragMove();
    }

    private void OpenSettings(object sender, RoutedEventArgs e) => openSettings();
    private void CloseWindow(object sender, RoutedEventArgs e) => Close();
    private async void OnTranslate(object sender, RoutedEventArgs e) => await TranslateAsync();

    private async void PasteAndTranslate(object sender, RoutedEventArgs e)
    {
        try
        {
            var text = Clipboard.GetText();
            if (string.IsNullOrWhiteSpace(text))
            {
                SetNotice("剪贴板中没有可翻译的文字");
                Editor.Focus();
                return;
            }
            CancelWork();
            Editor.Text = text;
            Editor.CaretIndex = Editor.Text.Length;
            await TranslateAsync();
        }
        catch (ExternalException) { SetNotice("无法读取剪贴板，请重试。"); }
    }

    private void CopySource(object sender, RoutedEventArgs e) => Copy(Editor.Text, SourceCopyIcon);

    private void Copy(string text, Icon icon)
    {
        try
        {
            Clipboard.SetText(text);
            icon.Glyph = "check";
            SetNotice(null);
        }
        catch (ExternalException) { SetNotice("无法写入剪贴板，请重试。"); }
    }

    private void SpeakSource(object sender, RoutedEventArgs e) => Speak(Editor.Text, TranslationLanguage.Find(preferences.Source), null);

    private void Speak(string text, TranslationLanguage? language, TranslationResultCard? result)
    {
        var toggleOff = speech is not null && speakingResult == result;
        StopSpeech();
        SetNotice(null);
        if (toggleOff) return;

        language ??= TranslationLanguage.Detect(text);
        if (language is null || (!language.IsChinese && language.Code != "en"))
        {
            SetNotice("离线朗读支持中文和英语。");
            return;
        }
        try
        {
            var engine = speech = new SpeechSynthesizer();
            var voices = engine.GetInstalledVoices().Where(item => item.Enabled)
                .Select(item => item.VoiceInfo)
                .Where(voice => voice.Culture.TwoLetterISOLanguageName == (language.IsChinese ? "zh" : "en")).ToArray();
            var voice = voices.FirstOrDefault(voice => voice.Culture.Name == language.VoiceLocale) ?? voices.FirstOrDefault();
            if (voice is null) throw new InvalidOperationException();
            engine.SelectVoice(voice.Name);
            engine.SpeakCompleted += (_, _) => Dispatcher.BeginInvoke(DispatcherPriority.Normal, () =>
            {
                if (speech == engine) StopSpeech();
            });
            speakingResult = result;
            (result?.ResultSpeaker ?? SourceSpeaker).Glyph = "square";
            engine.SpeakAsync(text);
        }
        catch (Exception error) when (error is InvalidOperationException or ArgumentException or COMException or NotSupportedException)
        {
            StopSpeech();
            SetNotice($"未找到可用的本机{language.Title}语音，请在 Windows 语音设置中检查。");
        }
    }

    private void StopSpeech()
    {
        var engine = speech;
        speech = null;
        if (engine is null) return;
        engine.Dispose();
        (speakingResult?.ResultSpeaker ?? SourceSpeaker).Glyph = "volume-2";
        speakingResult = null;
    }

    private void SetNotice(string? text)
    {
        Notice.Text = text ?? "";
        Notice.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
    }
}
