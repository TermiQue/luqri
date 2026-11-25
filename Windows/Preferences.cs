using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Input;

namespace Luqri;

internal enum Command { Translate = 1, Recognize, ScreenshotTranslate }

internal sealed record CommandInfo(Command Id, string Title, string Icon, Shortcut Default)
{
    public static readonly CommandInfo[] All =
    [
        new(Command.Translate, "划词翻译", "languages", new(ModifierKeys.Alt, Key.D)),
        new(Command.Recognize, "OCR 识别", "scan-text", new(ModifierKeys.Alt, Key.W)),
        new(Command.ScreenshotTranslate, "OCR 翻译", "languages", new(ModifierKeys.Alt, Key.S))
    ];
}

internal sealed record Shortcut(ModifierKeys Modifiers, Key Key)
{
    public override string ToString()
    {
        var parts = new List<string>();
        if (Modifiers.HasFlag(ModifierKeys.Control)) parts.Add("Ctrl");
        if (Modifiers.HasFlag(ModifierKeys.Alt)) parts.Add("Alt");
        if (Modifiers.HasFlag(ModifierKeys.Shift)) parts.Add("Shift");
        if (Modifiers.HasFlag(ModifierKeys.Windows)) parts.Add("Win");
        parts.Add(Key is >= Key.D0 and <= Key.D9 ? ((int)(Key - Key.D0)).ToString() : Key.ToString());
        return string.Join("+", parts);
    }

    public bool IsValid => Key > Key.None && Key <= Key.OemClear &&
        Key is not (Key.Escape or Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or
            Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin or Key.F12) &&
        (Modifiers & (ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Windows)) != 0 &&
        (Modifiers != ModifierKeys.Control ||
            Key is not (Key.OemComma or Key.A or Key.C or Key.H or Key.M or Key.Q or
                Key.V or Key.W or Key.X or Key.Y or Key.Z or Key.Enter));
}

internal sealed record TranslationLanguage(string Code, string Title)
{
    public override string ToString() => Title;

    public bool IsChinese => Code.StartsWith("zh", StringComparison.Ordinal);
    public string CloudCode => Code == "zh-Hans" ? "zh" : Code;
    public string VoiceLocale => Code switch { "zh-Hans" => "zh-CN", "zh-Hant" => "zh-TW", _ => Code };

    public static readonly TranslationLanguage[] All =
    [
        new("zh-Hans", "简体中文"), new("zh-Hant", "繁體中文"), new("en", "英语"),
        new("ja", "日语"), new("ko", "韩语"), new("fr", "法语"),
        new("de", "德语"), new("es", "西班牙语"), new("it", "意大利语"),
        new("pt", "葡萄牙语"), new("ru", "俄语"), new("ar", "阿拉伯语")
    ];

    public static TranslationLanguage? Find(string? code) => All.FirstOrDefault(l => l.Code == code);

    public static TranslationLanguage TargetFor(string text, TranslationLanguage? source)
        => (source ?? Detect(text))?.IsChinese == true ? All[2] : All[0];

    public static TranslationLanguage? Detect(string text)
    {
        var end = Math.Min(512, text.Length);
        if (end < text.Length && char.IsLowSurrogate(text[end])) end--;
        var sample = text[..end];
        if (sample.Length <= 16 && sample.All(ch => ch < 128) && Regex.IsMatch(sample, "[a-zA-Z]")) return All[2];
        // Skip the native recognizer for malformed Unicode pasted from third-party apps.
        string? code;
        try { code = LanguageDetection.Detect(sample); }
        catch (ArgumentException) { code = null; }
        if (!string.IsNullOrEmpty(code) && code is not ("und" or "unknown"))
            return Find(code);
        if (Regex.IsMatch(sample, @"[\u3040-\u30ff\uac00-\ud7af\u1100-\u11ff\u0400-\u052f\u0600-\u06ff]")) return null;
        if (Regex.IsMatch(sample, @"[\u3400-\u9fff\uf900-\ufaff]|[\ud840-\ud88c][\udc00-\udfff]")) return All[0];
        return Regex.IsMatch(sample, "[a-zA-Z]") ? All[2] : null;
    }
}

internal sealed record Credentials(string AccessKey, string SecretKey);

internal sealed class Preferences
{
    private static readonly string DirectoryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Luqri");
    private static string SettingsPath => Path.Combine(DirectoryPath, "settings.json");
    private static string CredentialsPath(CloudProvider provider) =>
        Path.Combine(DirectoryPath, provider == CloudProvider.Aliyun ? "aliyun.bin" : "volcengine.bin");

    public string? Source { get; set; }
    public string? Target { get; set; }
    public bool TranslationEnabled { get; set; } = true;
    public CloudProvider TranslationProvider
    {
        get;
        set => field = value == CloudProvider.Aliyun ? value : CloudProvider.Volcengine;
    }
    public CloudProvider OcrProvider
    {
        get;
        set => field = value == CloudProvider.Aliyun ? value : CloudProvider.Volcengine;
    }
    public Dictionary<Command, Shortcut> Bindings { get; init; } = new();

    public Shortcut Binding(CommandInfo command) => Bindings.TryGetValue(command.Id, out var shortcut) && shortcut.IsValid
        ? shortcut : command.Default;

    public static Preferences Load()
    {
        try { return JsonSerializer.Deserialize<Preferences>(File.ReadAllBytes(SettingsPath)) ?? new(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return new(); }
    }

    public void Save() => WriteAtomically(SettingsPath, JsonSerializer.SerializeToUtf8Bytes(this));

    public static Credentials RequireCredentials(CloudProvider provider) => ReadCredentials(provider) ??
        throw new InvalidOperationException($"请在设置中填写{CloudServices.Name(provider)}访问密钥。");

    public static Credentials? ReadCredentials(CloudProvider provider)
    {
        try
        {
            var bytes = ProtectedData.Unprotect(File.ReadAllBytes(CredentialsPath(provider)), null, DataProtectionScope.CurrentUser);
            try { return JsonSerializer.Deserialize<Credentials>(bytes); }
            finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) { return null; }
    }

    public static void SaveCredentials(CloudProvider provider, Credentials credentials)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(credentials);
        try { WriteAtomically(CredentialsPath(provider), ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser)); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    public static void RemoveCredentials(CloudProvider provider) => File.Delete(CredentialsPath(provider));

    private static void WriteAtomically(string path, byte[] data)
    {
        Directory.CreateDirectory(DirectoryPath);
        var temporary = path + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, data);
            File.Move(temporary, path, overwrite: true);
        }
        finally { File.Delete(temporary); }
    }
}
