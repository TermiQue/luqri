using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace Luqri;

internal static class Native
{
    [DllImport("user32", SetLastError = true)] internal static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
    [DllImport("user32")] internal static extern bool UnregisterHotKey(nint window, int id);
    [DllImport("user32")] internal static extern nint GetForegroundWindow();
    [DllImport("user32")] internal static extern bool SetForegroundWindow(nint window);
    [DllImport("user32")] internal static extern uint GetWindowThreadProcessId(nint window, out uint processId);
    [DllImport("user32")] internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32")] internal static extern nint GetClipboardOwner();
    [DllImport("user32")] internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32")] private static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32")] private static extern bool GetWindowRect(nint window, out WindowRect rect);
    [DllImport("user32")] internal static extern bool SetWindowDisplayAffinity(nint window, uint affinity);
    [DllImport("dwmapi")] internal static extern int DwmFlush();

    private const uint DontSize = 0x0001;
    private const uint DontChangeZOrder = 0x0004;
    private const uint DontActivate = 0x0010;

    [StructLayout(LayoutKind.Sequential)]
    private struct WindowRect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct Input { public uint Type; public InputData Data; }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputData
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort Key, ScanCode;
        public uint Flags, Time;
        public nuint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X, Y;
        public uint MouseData, Flags, Time;
        public nuint ExtraInfo;
    }

    internal static bool CopyKeystroke()
    {
        var inputs = new[] { KeyInput(0x11), KeyInput(0x43), KeyInput(0x43, true), KeyInput(0x11, true) };
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>()) == inputs.Length;
    }

    private static Input KeyInput(ushort key, bool up = false) => new()
    {
        Type = 1, Data = new() { Keyboard = new() { Key = key, Flags = up ? 2u : 0u } }
    };

    internal static bool IsDown(int key) => GetAsyncKeyState(key) < 0;

    internal static nint WindowHandle(Window window) => new WindowInteropHelper(window).EnsureHandle();

    internal static void KeepOnScreen(Window window)
    {
        var handle = WindowHandle(window);
        if (!GetWindowRect(handle, out var rect)) return;
        var work = Forms.Screen.FromHandle(handle).WorkingArea;
        var x = Math.Clamp(rect.Left, work.Left, Math.Max(work.Left, work.Right - (rect.Right - rect.Left)));
        var y = Math.Clamp(rect.Top, work.Top, Math.Max(work.Top, work.Bottom - (rect.Bottom - rect.Top)));
        if (x != rect.Left || y != rect.Top) SetWindowPos(handle, 0, x, y, 0, 0, DontChangeZOrder | DontActivate | DontSize);
    }

    internal static void FitOverlay(Window window, Drawing.Rectangle bounds)
    {
        var hwnd = WindowHandle(window);
        SetWindowPos(hwnd, 0, bounds.X, bounds.Y, bounds.Width, bounds.Height, DontChangeZOrder | DontActivate);
        var scale = Math.Max(96, GetDpiForWindow(hwnd)) / 96.0;
        window.Width = bounds.Width / scale;
        window.Height = bounds.Height / scale;
        SetWindowPos(hwnd, 0, bounds.X, bounds.Y, bounds.Width, bounds.Height, DontChangeZOrder | DontActivate);
    }

    internal static void ShowPositioned(Window window, Drawing.Point anchor, bool aboveCenter = false, bool byCursor = false)
    {
        var opacity = window.Opacity;
        // SizeToContent settles during the first layout, so keep layered windows transparent until they are positioned.
        if (window.AllowsTransparency) window.SetCurrentValue(UIElement.OpacityProperty, 0.0);

        var hwnd = WindowHandle(window);
        var screen = Forms.Screen.FromPoint(anchor);
        var work = screen.WorkingArea;
        SetWindowPos(hwnd, 0, work.Left, work.Top, 0, 0, DontChangeZOrder | DontActivate | DontSize);
        var scale = Math.Max(96, GetDpiForWindow(hwnd)) / 96.0;
        window.MaxWidth = Math.Max(1, work.Width / scale - 16);
        window.MaxHeight = Math.Max(1, work.Height / scale - 16);
        window.Top = work.Top / scale;
        window.Left = work.Left / scale;
        window.Show();
        window.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
        {
            if (!window.IsVisible) return;
            window.UpdateLayout();
            if (GetWindowRect(hwnd, out var rect))
            {
                var width = rect.Right - rect.Left;
                var height = rect.Bottom - rect.Top;
                var x = byCursor ? anchor.X + 12 : work.Left + (work.Width - width) / 2;
                var y = byCursor ? anchor.Y + 12 : work.Top + (work.Height - height) / 2;
                if (aboveCenter) y -= (int)(screen.Bounds.Height * 0.12);
                x = Math.Clamp(x, work.Left + 4, Math.Max(work.Left + 4, work.Right - width - 4));
                y = Math.Clamp(y, work.Top + 4, Math.Max(work.Top + 4, work.Bottom - height - 4));
                SetWindowPos(hwnd, 0, x, y, 0, 0, DontChangeZOrder | DontActivate | DontSize);
            }
            if (window.AllowsTransparency) window.SetCurrentValue(UIElement.OpacityProperty, opacity);
        });
    }
}

internal sealed class GlobalShortcuts : IDisposable
{
    private readonly HwndSource source;
    private readonly Preferences preferences;
    private readonly HashSet<Command> unavailable = new();
    public event Action<Command>? Invoked;

    public GlobalShortcuts(Preferences preferences)
    {
        this.preferences = preferences;
        source = new HwndSource(new HwndSourceParameters("Luqri hotkeys") { ParentWindow = new nint(-3) });
        source.AddHook(ProcessMessage);
        RegisterAll();
    }

    public bool IsUnavailable(Command command) => unavailable.Contains(command);

    public string? Change(CommandInfo command, Shortcut shortcut)
    {
        if (!shortcut.IsValid) return "请同时按下 Ctrl、Alt 或 Win 与其他按键，并避开应用快捷键。";
        if (CommandInfo.All.Any(other => other.Id != command.Id && preferences.Binding(other) == shortcut))
            return "该组合已用于 Luqri 中的其他操作。";
        var previous = preferences.Binding(command);
        if (previous == shortcut && !IsUnavailable(command.Id)) return null;

        Native.UnregisterHotKey(source.Handle, (int)command.Id);
        if (!Register(command.Id, shortcut))
        {
            Register(command.Id, previous);
            return "Windows 未能注册该组合，可能已被系统或其他应用占用。";
        }

        var hadBinding = preferences.Bindings.TryGetValue(command.Id, out var oldBinding);
        preferences.Bindings[command.Id] = shortcut;
        try { preferences.Save(); }
        catch (Exception error)
        {
            if (hadBinding) preferences.Bindings[command.Id] = oldBinding!;
            else preferences.Bindings.Remove(command.Id);
            Native.UnregisterHotKey(source.Handle, (int)command.Id);
            Register(command.Id, previous);
            return $"无法保存快捷键。{error.Message}";
        }
        return null;
    }

    public void RestoreDefaults()
    {
        var previous = preferences.Bindings.ToArray();
        preferences.Bindings.Clear();
        try { preferences.Save(); }
        catch
        {
            foreach (var (command, shortcut) in previous) preferences.Bindings.Add(command, shortcut);
            throw;
        }
        UnregisterAll();
        RegisterAll();
    }

    private void RegisterAll()
    {
        foreach (var command in CommandInfo.All) Register(command.Id, preferences.Binding(command));
    }

    private bool Register(Command command, Shortcut shortcut)
    {
        // ModifierKeys uses the same bit values as RegisterHotKey.
        var success = Native.RegisterHotKey(source.Handle, (int)command, (uint)shortcut.Modifiers | 0x4000,
            (uint)KeyInterop.VirtualKeyFromKey(shortcut.Key));
        if (success) unavailable.Remove(command);
        else unavailable.Add(command);
        return success;
    }

    private nint ProcessMessage(nint window, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message != 0x0312) return 0;
        handled = true;
        Invoked?.Invoke((Command)wParam);
        return 0;
    }

    private void UnregisterAll()
    {
        foreach (var command in CommandInfo.All) Native.UnregisterHotKey(source.Handle, (int)command.Id);
    }

    public void Dispose()
    {
        UnregisterAll();
        source.Dispose();
    }
}
