using System.Net.Http;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace Luqri;

public partial class App : Application
{
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(20) };
    private readonly UsageCache usage = new();
    private readonly CancellationTokenSource usageTracking = new();
    private readonly SelectionReader selection = new();
    private readonly ScreenCapture capture = new();
    private readonly Dictionary<Command, Forms.ToolStripMenuItem> trayCommands = new();
    private Preferences preferences = null!;
    private GlobalShortcuts? shortcuts;
    private CloudServices cloud = null!;
    private Forms.NotifyIcon? tray;
    private Forms.ContextMenuStrip? menu;
    private Drawing.Icon? trayIcon;
    private readonly Dictionary<string, Drawing.Bitmap> menuIcons = new();
    private Mutex? instance;
    private EventWaitHandle? requestSettings;
    private RegisteredWaitHandle? settingsListener;
    private SettingsWindow? settings;
    private TranslationWindow? translation;
    private Window? feedback;
    private CancellationTokenSource? work;
    private nint trayForeground;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        const string instanceName = @"Local\Luqri.Windows";
        instance = new Mutex(false, instanceName, out var first);
        requestSettings = new EventWaitHandle(false, EventResetMode.AutoReset, instanceName + ".Settings");
        if (!first)
        {
            requestSettings.Set();
            Shutdown();
            return;
        }
        settingsListener = ThreadPool.RegisterWaitForSingleObject(requestSettings, (_, _) =>
            Dispatcher.BeginInvoke(DispatcherPriority.Normal, ShowSettings), null, Timeout.Infinite, false);

        ApplyTheme();
        preferences = Preferences.Load();
        cloud = new CloudServices(http);
        shortcuts = new GlobalShortcuts(preferences);
        shortcuts.Invoked += command =>
        {
            if (settings?.HandleRegisteredShortcut(command) != true)
                _ = RunAsync(command, Native.GetForegroundWindow());
        };
        BuildTray();
        var trackingToken = usageTracking.Token;
        _ = Task.Run(() => TrackVolcengineOcrUsageAsync(trackingToken), trackingToken);
        if (e.Args.Contains("--settings")) ShowSettings();
    }

    private async Task TrackVolcengineOcrUsageAsync(CancellationToken token)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromHours(1));
        try
        {
            do
            {
                try
                {
                    if (Preferences.ReadCredentials(CloudProvider.Volcengine) is { } credentials)
                        await cloud[CloudProvider.Volcengine].ReadOcrUsageAsync(credentials, DateTimeOffset.UtcNow, token)
                            .ConfigureAwait(false);
                }
                catch (Exception error)
                {
                    if (!token.IsCancellationRequested) System.Diagnostics.Debug.WriteLine(error.Message);
                }
            } while (await timer.WaitForNextTickAsync(token).ConfigureAwait(false));
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
    }

    private void ApplyTheme()
    {
        if (SystemParameters.HighContrast) return;
        var light = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            "AppsUseLightTheme", 1);
        if (light is not 0) return;
        var colors = new Dictionary<string, string>
        {
            ["Surface"] = "#232323", ["Card"] = "#303030", ["SettingsCard"] = "#292929",
            ["Ink"] = "#F4F4F4", ["Muted"] = "#B8B8B8", ["Line"] = "#494949",
            ["Hover"] = "#454545", ["ButtonFill"] = "#434343", ["FocusRing"] = "#659DFC",
            ["Danger"] = "#FF9D97"
        };
        foreach (var (name, hex) in colors)
            Resources[name] = new System.Windows.Media.SolidColorBrush((System.Windows.Media.Color)
                System.Windows.Media.ColorConverter.ConvertFromString(hex));
    }

    private void BuildTray()
    {
        using var stream = typeof(App).Assembly.GetManifestResourceStream("Luqri.Luqri.ico")!;
        using var icon = new Drawing.Icon(stream);
        trayIcon = (Drawing.Icon)icon.Clone();
        menu = new Forms.ContextMenuStrip();
        menu.Opening += (_, _) => LoadTrayImages();
        foreach (var command in CommandInfo.All)
        {
            var item = new Forms.ToolStripMenuItem(command.Title);
            item.Click += (_, _) =>
            {
                if (trayForeground != 0) Native.SetForegroundWindow(trayForeground);
                _ = RunAsync(command.Id, trayForeground);
            };
            menu.Items.Add(item);
            trayCommands.Add(command.Id, item);
        }
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("设置…", null, (_, _) => ShowSettings());
        menu.Items.Add("退出 Luqri", null, (_, _) => Shutdown());
        RefreshTray();
        tray = new Forms.NotifyIcon { Icon = trayIcon, ContextMenuStrip = menu, Text = "Luqri", Visible = true };
        tray.MouseDown += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Right) trayForeground = Native.GetForegroundWindow();
        };
        tray.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) ShowSettings(); };
    }

    private void LoadTrayImages()
    {
        foreach (var command in CommandInfo.All)
        {
            var item = trayCommands[command.Id];
            if (item.Image is not null) continue;
            if (!menuIcons.TryGetValue(command.Icon, out var image))
            {
                if (command.Icon == "languages" && trayIcon is not null)
                {
                    using var smallIcon = new Drawing.Icon(trayIcon, 16, 16);
                    image = smallIcon.ToBitmap();
                }
                else image = IconBitmap(command.Icon);
                menuIcons.Add(command.Icon, image);
            }
            item.Image = image;
        }
    }

    private static Drawing.Bitmap IconBitmap(string glyph)
    {
        var visual = new System.Windows.Media.DrawingVisual();
        using (var context = visual.RenderOpen())
        {
            context.PushTransform(new System.Windows.Media.ScaleTransform(0.65, 0.65));
            var pen = new System.Windows.Media.Pen(System.Windows.Media.Brushes.DimGray, 1.8);
            context.DrawGeometry(null, pen, Icon.DrawingFor(glyph));
        }
        var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap(16, 16, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
        bitmap.Render(visual);
        const Drawing.Imaging.PixelFormat format = Drawing.Imaging.PixelFormat.Format32bppPArgb;
        var image = new Drawing.Bitmap(16, 16, format);
        try
        {
            var bits = image.LockBits(new Drawing.Rectangle(0, 0, 16, 16), Drawing.Imaging.ImageLockMode.WriteOnly, format);
            try { bitmap.CopyPixels(Int32Rect.Empty, bits.Scan0, bits.Stride * 16, bits.Stride); }
            finally { image.UnlockBits(bits); }
            return image;
        }
        catch { image.Dispose(); throw; }
    }

    private void RefreshTray()
    {
        foreach (var command in CommandInfo.All)
            trayCommands[command.Id].ShortcutKeyDisplayString = shortcuts?.IsUnavailable(command.Id) == false
                ? preferences.Binding(command).ToString() : "";
    }

    private void ShowSettings()
    {
        if (settings is null)
        {
            var window = new SettingsWindow(preferences, shortcuts!, cloud, usage,
                () => translation?.PreferencesChanged(), RefreshTray);
            settings = window;
            window.Closed += (_, _) => settings = null;
            Native.ShowPositioned(window, Forms.Cursor.Position);
        }
        else
        {
            if (settings.WindowState == WindowState.Minimized) settings.WindowState = WindowState.Normal;
            if (!settings.IsVisible) settings.Show();
            settings.Activate();
        }
    }

    internal void HideWindows()
    {
        capture.Cancel();
        feedback?.Close();
        translation?.Close();
        settings?.Hide();
    }

    private async Task RunAsync(Command command, nint foreground)
    {
        work?.Cancel();
        capture.Cancel();
        feedback?.Close();
        var current = work = new CancellationTokenSource();
        var anchor = Forms.Cursor.Position;
        var ocrProvider = preferences.OcrProvider;
        try
        {
            if (command == Command.Translate)
            {
                var text = await selection.ReadAsync(foreground, current.Token);
                current.Token.ThrowIfCancellationRequested();
                if (Native.GetForegroundWindow() != foreground) text = null;
                await ShowTranslationAsync(anchor, text);
                return;
            }

            translation?.Close();
            var region = await capture.SelectAsync();
            current.Token.ThrowIfCancellationRequested();
            if (region is null) return;
            anchor = region.Anchor;
            var pixels = ScreenCapture.Capture(region);
            if (command == Command.ScreenshotTranslate) await ShowTranslationAsync(anchor, image: pixels, ocrProvider: ocrProvider);
            else
            {
                var credentials = Preferences.RequireCredentials(ocrProvider);
                var text = await cloud[ocrProvider].RecognizeAsync(pixels, credentials, current.Token);
                current.Token.ThrowIfCancellationRequested();
                Clipboard.SetText(text);
            }
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (!current.IsCancellationRequested)
            {
                if (command == Command.Translate) await ShowTranslationAsync(anchor);
                else ShowOcrError(CloudServices.DescribeError(ocrProvider, error), anchor);
            }
        }
        finally
        {
            if (work == current) work = null;
            current.Dispose();
        }
    }

    private Task ShowTranslationAsync(Drawing.Point anchor, string? text = null,
        System.Windows.Media.Imaging.BitmapSource? image = null, CloudProvider ocrProvider = CloudProvider.Volcengine)
    {
        translation?.Close();
        var window = new TranslationWindow(preferences, cloud, ShowSettings);
        translation = window;
        window.Closed += (_, _) => translation = null;
        DispatcherOperation? positionUpdate = null;
        window.SizeChanged += (_, _) =>
        {
            if (positionUpdate is { Status: DispatcherOperationStatus.Pending }) return;
            positionUpdate = window.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
            {
                if (window.IsVisible) Native.KeepOnScreen(window);
            });
        };
        Native.ShowPositioned(window, anchor, aboveCenter: true);
        window.Activate();
        return window.LoadAsync(text, image, ocrProvider);
    }

    private void ShowOcrError(string text, Drawing.Point anchor)
    {
        feedback?.Close();
        var label = new System.Windows.Controls.TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, MaxWidth = 316 };
        label.SetResourceReference(System.Windows.Controls.TextBlock.ForegroundProperty, "Ink");
        var card = new System.Windows.Controls.Border
        {
            Padding = new(12, 9, 12, 9), CornerRadius = new(9), BorderThickness = new(1), Child = label
        };
        card.SetResourceReference(System.Windows.Controls.Border.BackgroundProperty, "Surface");
        card.SetResourceReference(System.Windows.Controls.Border.BorderBrushProperty, "Line");
        var window = new Window
        {
            Title = "OCR 识别失败", SizeToContent = SizeToContent.WidthAndHeight, Topmost = true,
            AllowsTransparency = true, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize,
            Background = System.Windows.Media.Brushes.Transparent, Content = card,
            ShowInTaskbar = false, ShowActivated = false, FontSize = 13
        };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        timer.Tick += (_, _) => window.Close();
        window.MouseLeftButtonDown += (_, _) => window.Close();
        window.Closed += (_, _) => { timer.Stop(); feedback = null; };
        feedback = window;
        Native.ShowPositioned(window, anchor, byCursor: true);
        timer.Start();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        work?.Cancel();
        usageTracking.Cancel();
        usageTracking.Dispose();
        capture.Cancel();
        settingsListener?.Unregister(null);
        requestSettings?.Dispose();
        instance?.Dispose();
        shortcuts?.Dispose();
        tray?.Dispose();
        menu?.Dispose();
        foreach (var image in menuIcons.Values) image.Dispose();
        trayIcon?.Dispose();
        http.Dispose();
        base.OnExit(e);
    }
}
