using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Navigation;

namespace Luqri;

internal sealed class UsageCache
{
    public Dictionary<CloudProvider, (Credentials Credentials, string Month, decimal Total)> Entries { get; } = new();
}

public partial class SettingsWindow : Window
{
    private sealed record ProviderChoice(CloudProvider Value, string Title)
    {
        public override string ToString() => Title;
    }

    private static readonly ProviderChoice[] Providers =
    [
        new(CloudProvider.Volcengine, CloudServices.Name(CloudProvider.Volcengine)),
        new(CloudProvider.Aliyun, CloudServices.Name(CloudProvider.Aliyun))
    ];

    private readonly Preferences preferences;
    private readonly GlobalShortcuts shortcuts;
    private readonly CloudServices cloud;
    private readonly UsageCache usageCache;
    private readonly Action preferencesChanged;
    private readonly Action bindingsChanged;
    private readonly Dictionary<Command, (Button Button, TextBlock Warning)> shortcutWidgets = new();
    private readonly Dictionary<CloudProvider, Credentials> credentialDrafts = new();
    private CommandInfo? recording;
    private CancellationTokenSource? usageRequest;
    private CloudProvider editingProvider;
    private bool initialized;

    internal SettingsWindow(Preferences preferences, GlobalShortcuts shortcuts, CloudServices cloud,
        UsageCache usageCache, Action preferencesChanged, Action bindingsChanged)
    {
        this.preferences = preferences;
        this.shortcuts = shortcuts;
        this.cloud = cloud;
        this.usageCache = usageCache;
        this.preferencesChanged = preferencesChanged;
        this.bindingsChanged = bindingsChanged;
        InitializeComponent();
        using (var icon = typeof(App).Assembly.GetManifestResourceStream("Luqri.Luqri.ico"))
            if (icon is not null) Icon = System.Windows.Media.Imaging.BitmapFrame.Create(
                icon, System.Windows.Media.Imaging.BitmapCreateOptions.None, System.Windows.Media.Imaging.BitmapCacheOption.OnLoad);

        PopulateLanguage(SourceLanguage, "自动检测", preferences.Source);
        PopulateLanguage(TargetLanguage, "自动选择", preferences.Target);
        PopulateProvider(TranslationProvider, preferences.TranslationProvider);
        PopulateProvider(OcrProvider, preferences.OcrProvider);
        editingProvider = preferences.TranslationProvider == CloudProvider.Aliyun ? CloudProvider.Aliyun : preferences.OcrProvider;
        PopulateProvider(CredentialProvider, editingProvider);
        UpdateBillingLinks();
        EnableCloud.IsChecked = preferences.TranslationEnabled;
        BuildShortcutRows();
        LoadCredentials();
        initialized = true;
        UpdateCredentialControls();
        UpdateShortcuts();
        Loaded += (_, _) => _ = RefreshUsageAsync();
    }

    private static void PopulateProvider(ComboBox box, CloudProvider value)
    {
        box.ItemsSource = Providers;
        SelectProvider(box, value);
    }

    private static void SelectProvider(ComboBox box, CloudProvider value) =>
        box.SelectedItem = Providers.First(choice => choice.Value == value);

    private void UpdateBillingLinks()
    {
        TranslationBilling.NavigateUri = new(preferences.TranslationProvider == CloudProvider.Aliyun
            ? "https://help.aliyun.com/zh/machine-translation/product-overview/pricing-of-machine-translation-general-purpose-edition"
            : "https://docs.volcengine.com/docs/machine-translation/product-billing");
        OcrBilling.NavigateUri = new(preferences.OcrProvider == CloudProvider.Aliyun
            ? "https://help.aliyun.com/zh/ocr/product-overview/recognition-of-characters-in-languages-except-for-chinese-and-english-1"
            : "https://docs.volcengine.com/docs/large-model-of-image-generation/ability-to-introduce-1");
    }

    private static void PopulateLanguage(ComboBox box, string automatic, string? code)
    {
        var languages = new[] { new TranslationLanguage("", automatic) }.Concat(TranslationLanguage.All).ToArray();
        box.ItemsSource = languages;
        box.SelectedItem = languages.FirstOrDefault(language => language.Code == code) ?? languages[0];
    }

    private void BuildShortcutRows()
    {
        var index = 0;
        foreach (var command in CommandInfo.All)
        {
            var button = new Button
            {
                Style = (Style)FindResource("FlatButton"), FontFamily = new FontFamily("Consolas"),
                MinWidth = 72, VerticalAlignment = VerticalAlignment.Center, ToolTip = "点击录制快捷键，按 Esc 取消"
            };
            button.Click += (_, _) =>
            {
                recording = command;
                ShortcutStatus.Text = "按 Esc 取消录制";
                button.Focus();
                UpdateShortcuts();
            };
            var warning = new TextBlock { Text = "不可用", Margin = new(0, 0, 7, 0) };
            warning.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
            var row = new DockPanel { Style = (Style)FindResource("Row") };
            DockPanel.SetDock(button, Dock.Right);
            DockPanel.SetDock(warning, Dock.Right);
            row.Children.Add(button);
            row.Children.Add(warning);
            row.Children.Add(new TextBlock { Text = command.Title });
            ShortcutRows.Children.Insert(index++, row);
            ShortcutRows.Children.Insert(index++, new Border { Style = (Style)FindResource("Divider") });
            shortcutWidgets.Add(command.Id, (button, warning));
        }
    }

    private void UpdateShortcuts()
    {
        foreach (var command in CommandInfo.All)
        {
            var (button, warning) = shortcutWidgets[command.Id];
            button.Content = recording?.Id == command.Id ? "请按键…" : preferences.Binding(command).ToString();
            AutomationProperties.SetName(button, $"{command.Title} {button.Content}");
            warning.Visibility = shortcuts.IsUnavailable(command.Id) ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    internal bool HandleRegisteredShortcut(Command id)
    {
        if (recording is null) return false;
        var binding = preferences.Binding(CommandInfo.All.Single(command => command.Id == id));
        RecordShortcut(binding);
        return true;
    }

    private void RecordShortcut(Shortcut binding)
    {
        if (recording is not { } command) return;
        var error = shortcuts.Change(command, binding);
        if (error is null)
        {
            StopRecording();
            bindingsChanged();
        }
        else ShortcutStatus.Text = error;
        UpdateShortcuts();
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var modifiers = Keyboard.Modifiers;
        if (recording is not null)
        {
            e.Handled = true;
            if (e.IsRepeat || key is Key.None or Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or
                Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) return;
            if (key == Key.Escape) StopRecording();
            else RecordShortcut(new(modifiers, key));
            return;
        }

        if (key == Key.Escape || (modifiers == ModifierKeys.Control && key == Key.W))
        {
            e.Handled = true;
            Close();
        }
        else if (modifiers == ModifierKeys.Control && key == Key.M)
        {
            e.Handled = true;
            WindowState = WindowState.Minimized;
        }
        else if (modifiers == ModifierKeys.Control && key == Key.H)
        {
            e.Handled = true;
            ((App)Application.Current).HideWindows();
        }
        else if (modifiers == ModifierKeys.Control && key == Key.Q)
        {
            e.Handled = true;
            Application.Current.Shutdown();
        }
    }

    private void StopRecording()
    {
        if (recording is null) return;
        recording = null;
        ShortcutStatus.Text = "";
        UpdateShortcuts();
    }

    private void OnDeactivated(object? sender, EventArgs e) => StopRecording();

    private void RestoreDefaults(object sender, RoutedEventArgs e)
    {
        StopRecording();
        try
        {
            shortcuts.RestoreDefaults();
            UpdateShortcuts();
            bindingsChanged();
        }
        catch (Exception error) { ShortcutStatus.Text = error.Message; }
    }

    private void LanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!initialized) return;
        var previousSource = preferences.Source;
        var previousTarget = preferences.Target;
        preferences.Source = TranslationLanguage.Find((SourceLanguage.SelectedItem as TranslationLanguage)?.Code)?.Code;
        preferences.Target = TranslationLanguage.Find((TargetLanguage.SelectedItem as TranslationLanguage)?.Code)?.Code;
        if (SavePreferences()) return;
        preferences.Source = previousSource;
        preferences.Target = previousTarget;
        initialized = false;
        PopulateLanguage(SourceLanguage, "自动检测", previousSource);
        PopulateLanguage(TargetLanguage, "自动选择", previousTarget);
        initialized = true;
    }

    private void CloudChanged(object sender, RoutedEventArgs e)
    {
        if (!initialized) return;
        var previous = preferences.TranslationEnabled;
        preferences.TranslationEnabled = EnableCloud.IsChecked == true;
        if (SavePreferences()) _ = RefreshUsageAsync();
        else
        {
            preferences.TranslationEnabled = previous;
            initialized = false;
            EnableCloud.IsChecked = previous;
            initialized = true;
        }
    }

    private void TranslationProviderChanged(object sender, SelectionChangedEventArgs e) => ChangeProvider(TranslationProvider, true);

    private void OcrProviderChanged(object sender, SelectionChangedEventArgs e) => ChangeProvider(OcrProvider, false);

    private void ChangeProvider(ComboBox box, bool translation)
    {
        if (!initialized || box.SelectedItem is not ProviderChoice choice) return;
        var previous = translation ? preferences.TranslationProvider : preferences.OcrProvider;
        if (translation) preferences.TranslationProvider = choice.Value;
        else preferences.OcrProvider = choice.Value;
        if (SavePreferences())
        {
            UpdateBillingLinks();
            if (translation) _ = RefreshUsageAsync();
            return;
        }

        if (translation) preferences.TranslationProvider = previous;
        else preferences.OcrProvider = previous;
        initialized = false;
        SelectProvider(box, previous);
        initialized = true;
    }

    private bool SavePreferences()
    {
        try { preferences.Save(); }
        catch (Exception error)
        {
            MessageBox.Show(this, $"无法保存设置。{error.Message}", Title, MessageBoxButton.OK, MessageBoxImage.Error);
            return false;
        }
        preferencesChanged();
        return true;
    }

    private void LoadCredentials()
    {
        CredentialStatus.Text = "";
        try
        {
            var credentials = Preferences.ReadCredentials(editingProvider);
            var fields = credentialDrafts.GetValueOrDefault(editingProvider) ?? credentials;
            AccessKey.Password = fields?.AccessKey ?? "";
            SecretKey.Password = fields?.SecretKey ?? "";
            RemoveKeys.Visibility = credentials is null ? Visibility.Collapsed : Visibility.Visible;
        }
        catch (Exception error)
        {
            AccessKey.Clear();
            SecretKey.Clear();
            RemoveKeys.Visibility = Visibility.Visible;
            CredentialStatus.Text = $"无法读取密钥。{error.Message}";
        }
    }

    private void CredentialProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!initialized || CredentialProvider.SelectedItem is not ProviderChoice choice) return;
        credentialDrafts[editingProvider] = new(AccessKey.Password, SecretKey.Password);
        editingProvider = choice.Value;
        LoadCredentials();
    }

    private void UpdateCredentialControls() => SaveKeys.IsEnabled =
        !string.IsNullOrWhiteSpace(AccessKey.Password) && !string.IsNullOrWhiteSpace(SecretKey.Password);

    private void CredentialChanged(object sender, RoutedEventArgs e)
    {
        if (initialized) UpdateCredentialControls();
    }

    private void PasteAccess(object sender, RoutedEventArgs e) => PasteKey(AccessKey);
    private void PasteSecret(object sender, RoutedEventArgs e) => PasteKey(SecretKey);

    private void PasteKey(PasswordBox field)
    {
        try { field.Password = Clipboard.GetText().Trim(); }
        catch (ExternalException) { CredentialStatus.Text = "无法读取剪贴板，请重试。"; }
    }

    private void SaveCredentials(object sender, RoutedEventArgs e)
    {
        try
        {
            Preferences.SaveCredentials(editingProvider, new(AccessKey.Password.Trim(), SecretKey.Password.Trim()));
            RemoveKeys.Visibility = Visibility.Visible;
            CredentialStatus.Text = "密钥已保存";
            CredentialsChanged();
        }
        catch (Exception error) { CredentialStatus.Text = error.Message; }
    }

    private void RemoveCredentials(object sender, RoutedEventArgs e)
    {
        try
        {
            Preferences.RemoveCredentials(editingProvider);
            AccessKey.Clear();
            SecretKey.Clear();
            RemoveKeys.Visibility = Visibility.Collapsed;
            CredentialStatus.Text = "密钥已移除";
            CredentialsChanged();
        }
        catch (Exception error) { CredentialStatus.Text = error.Message; }
    }

    private void CredentialsChanged()
    {
        credentialDrafts.Remove(editingProvider);
        usageCache.Entries.Remove(editingProvider);
        preferencesChanged();
        if (editingProvider == preferences.TranslationProvider) _ = RefreshUsageAsync();
    }

    private async Task RefreshUsageAsync()
    {
        usageRequest?.Cancel();
        usageRequest = null;
        UsageRing.Visibility = preferences.TranslationEnabled ? Visibility.Visible : Visibility.Hidden;
        TranslationBilling.IsEnabled = preferences.TranslationEnabled;
        if (!preferences.TranslationEnabled) return;

        var current = usageRequest = new CancellationTokenSource();
        var provider = preferences.TranslationProvider;
        var quota = provider == CloudProvider.Aliyun ? Aliyun.FreeCharacters : Volcengine.FreeCharacters;
        decimal? cached = null;
        try
        {
            var credentials = Preferences.ReadCredentials(provider);
            if (credentials is null)
            {
                DisplayUsage(null, quota, $"保存{CloudServices.Name(provider)}密钥后可查询本月用量。");
                return;
            }

            var now = DateTimeOffset.UtcNow;
            var month = CloudServices.BillingTime(now).ToString("yyyy-MM", CultureInfo.InvariantCulture);
            if (usageCache.Entries.TryGetValue(provider, out var entry) && entry.Credentials == credentials && entry.Month == month)
                cached = entry.Total;
            DisplayUsage(cached, quota, "正在查询本月机器翻译用量…");
            var used = await cloud[provider].ReadUsageAsync(credentials, now, current.Token);
            if (current.IsCancellationRequested) return;
            usageCache.Entries[provider] = (credentials, month, used);
            var amount = $"{used / 10000:N2} / {quota / 10000:N2} 万字符";
            var tooltip = provider == CloudProvider.Aliyun
                ? $"云端报表估算 · {amount}\n实际免费余额以阿里云控制台为准。"
                : amount;
            DisplayUsage(used, quota, tooltip);
        }
        catch (Exception error)
        {
            if (!current.IsCancellationRequested)
                DisplayUsage(cached, quota, $"无法查询本月用量。\n{CloudServices.DescribeError(provider, error)}");
        }
        finally
        {
            if (usageRequest == current) usageRequest = null;
            current.Dispose();
        }
    }

    private void DisplayUsage(decimal? used, decimal quota, string tooltip)
    {
        UsageRing.ToolTip = tooltip;
        AutomationProperties.SetName(UsageRing, tooltip);
        var fraction = (double)Math.Clamp((used ?? 0) / quota, 0, 1);
        if (fraction == 0) { UsageArc.Data = Geometry.Empty; return; }
        if (fraction >= 1) { UsageArc.Data = new EllipseGeometry(new Point(8, 8), 6.5, 6.5); return; }
        var angle = fraction * Math.Tau;
        var end = new Point(8 + 6.5 * Math.Sin(angle), 8 - 6.5 * Math.Cos(angle));
        var path = new PathFigure { StartPoint = new(8, 1.5), IsFilled = false };
        path.Segments.Add(new ArcSegment(end, new Size(6.5, 6.5), 0, fraction > 0.5, SweepDirection.Clockwise, true));
        UsageArc.Data = new PathGeometry([path]);
    }

    private void OnClosed(object? sender, EventArgs e) => usageRequest?.Cancel();

    private void OpenLink(object sender, RequestNavigateEventArgs e)
    {
        e.Handled = true;
        try { Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true }); }
        catch (Exception error) { MessageBox.Show(this, error.Message, Title); }
    }
}
