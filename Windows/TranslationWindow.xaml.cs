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
    private readonly Volcengine cloud;
    private readonly Action openSettings;
    private CancellationTokenSource? work;
    private SpeechSynthesizer? speech;
    private bool speakingResult;
    private bool pinned;
    private bool expanded = true;
    private bool loadingInput;
    private bool initialized;
    private TranslationLanguage? resultLanguage;
    private string? inputError;

    internal TranslationWindow(Preferences preferences, Volcengine cloud, Action openSettings)
    {
        this.preferences = preferences;
        this.cloud = cloud;
        this.openSettings = openSettings;
        InitializeComponent();
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

    internal async Task LoadAsync(string? text, BitmapSource? image)
    {
        if (image is not null)
        {
            CancelWork();
            var current = work = new CancellationTokenSource();
            loadingInput = true;
            inputError = null;
            UpdateControls();
            try { text = await cloud.RecognizeAsync(image, Preferences.RequireCredentials(), current.Token); }
            catch (OperationCanceledException) when (current.IsCancellationRequested) { return; }
            catch (Exception error)
            {
                if (current.IsCancellationRequested) return;
                inputError = Volcengine.DescribeError(error);
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
        if (input.Length == 0 || !preferences.TranslationEnabled || loadingInput || work is not null) return;

        expanded = true;
        ClearResult();
        StopSpeech();
        SetNotice(null);
        var current = work = new CancellationTokenSource();
        var source = TranslationLanguage.Find(preferences.Source);
        var target = TranslationLanguage.Find(preferences.Target) ?? TranslationLanguage.TargetFor(input, source);
        ResultStatus.Text = "正在翻译…";
        UpdateControls();
        try
        {
            var translated = await cloud.TranslateAsync(input, source, target, Preferences.RequireCredentials(), current.Token);
            if (current.IsCancellationRequested) return;
            Result.Text = translated;
            resultLanguage = target;
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (!current.IsCancellationRequested) ResultStatus.Text = Volcengine.DescribeError(error);
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
        Result.Text = "";
        resultLanguage = null;
        ResultCopyIcon.Glyph = "copy";
        ResultStatus.Text = "按 Ctrl+Enter 翻译";
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
        var hasResult = !string.IsNullOrEmpty(Result.Text);
        Editor.IsReadOnly = loadingInput;
        Placeholder.Visibility = Editor.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Placeholder.Text = loadingInput ? "正在识别文字…" : inputError ?? "输入或粘贴文字…";
        SourceSpeak.IsEnabled = SourceCopy.IsEnabled = hasText;
        TranslateButton.IsEnabled = hasText && !loadingInput && work is null && preferences.TranslationEnabled;
        PasteButton.IsEnabled = !loadingInput;
        DisabledCard.Visibility = preferences.TranslationEnabled ? Visibility.Collapsed : Visibility.Visible;
        ServiceCard.Visibility = preferences.TranslationEnabled ? Visibility.Visible : Visibility.Collapsed;
        ServiceHeader.IsEnabled = hasText;
        ResultPanel.Visibility = expanded && hasText ? Visibility.Visible : Visibility.Collapsed;
        Chevron.Glyph = ResultPanel.Visibility == Visibility.Visible ? "chevron-down" : "chevron-right";
        ResultStatus.Visibility = hasResult ? Visibility.Collapsed : Visibility.Visible;
        Result.Visibility = ResultActions.Visibility = hasResult ? Visibility.Visible : Visibility.Collapsed;
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

    private void ToggleResult(object sender, RoutedEventArgs e)
    {
        expanded = !expanded;
        if (!expanded && speakingResult) StopSpeech();
        UpdateControls();
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
    private void CopyResult(object sender, RoutedEventArgs e) => Copy(Result.Text, ResultCopyIcon);

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

    private void SpeakSource(object sender, RoutedEventArgs e) => Speak(Editor.Text, TranslationLanguage.Find(preferences.Source), false);
    private void SpeakResult(object sender, RoutedEventArgs e) => Speak(Result.Text, resultLanguage, true);

    private void Speak(string text, TranslationLanguage? language, bool result)
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
            (result ? ResultSpeaker : SourceSpeaker).Glyph = "square";
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
        ResultSpeaker.Glyph = SourceSpeaker.Glyph = "volume-2";
    }

    private void SetNotice(string? text)
    {
        Notice.Text = text ?? "";
        Notice.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
    }
}
