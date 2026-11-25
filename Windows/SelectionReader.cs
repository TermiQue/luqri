using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using DataObject = System.Runtime.InteropServices.ComTypes.IDataObject;

namespace Luqri;

internal sealed class SelectionReader
{
    private readonly SemaphoreSlim reader = new(1, 1);
    private Task<Selection>? pendingAutomation;
    private sealed record Selection(string? Text, bool Protected = false);

    public async Task<string?> ReadAsync(nint window, CancellationToken token)
    {
        Native.GetWindowThreadProcessId(window, out var processId);
        if (processId == 0 || processId == Environment.ProcessId) return null;

        await reader.WaitAsync(token);
        try
        {
            Selection? selection = null;
            if (pendingAutomation is null || pendingAutomation.IsCompleted)
            {
                pendingAutomation = Task.Run(() => ReadAutomation(processId));
                try { selection = await pendingAutomation.WaitAsync(TimeSpan.FromMilliseconds(350), token); }
                catch (TimeoutException) { }
            }
            if (Native.GetForegroundWindow() != window || selection?.Protected == true) return null;
            return selection?.Text ?? await CopyAsync(window, processId, token);
        }
        finally { reader.Release(); }
    }

    private static Selection ReadAutomation(uint processId)
    {
        try
        {
            var element = AutomationElement.FocusedElement;
            if (element is null || element.Current.ProcessId != processId) return new(null);
            for (var depth = 0; depth < 5 && element is not null; depth++)
            {
                if (element.Current.IsPassword) return new(null, true);
                if (element.TryGetCurrentPattern(TextPattern.Pattern, out var raw) && raw is TextPattern pattern)
                {
                    var text = string.Join("\n", pattern.GetSelection().Select(range => range.GetText(-1)));
                    if (!string.IsNullOrWhiteSpace(text)) return new(text);
                }
                element = TreeWalker.RawViewWalker.GetParent(element);
                if (element is not null && element.Current.ProcessId != processId) break;
            }
        }
        catch (Exception error) when (error is ElementNotAvailableException or COMException or InvalidOperationException) { }
        return new(null);
    }

    private static async Task<string?> CopyAsync(nint window, uint processId, CancellationToken token)
    {
        var until = Environment.TickCount64 + 550;
        while (ModifiersAreDown() && Environment.TickCount64 < until) await Task.Delay(20, token);
        if (ModifiersAreDown() || Native.GetForegroundWindow() != window) return null;

        // Capture the OLE object so the original clipboard formats can be restored together.
        var originalSequence = Native.GetClipboardSequenceNumber();
        if (OleGetClipboard(out var snapshot) != 0 || Native.GetClipboardSequenceNumber() != originalSequence) return null;
        uint? copySequence = null;
        try
        {
            token.ThrowIfCancellationRequested();
            if (!Native.CopyKeystroke()) return null;

            var (sequence, text) = await ReadNewClipboardAsync(originalSequence, window, processId);
            copySequence = sequence;
            token.ThrowIfCancellationRequested();
            return Native.GetForegroundWindow() == window && !string.IsNullOrWhiteSpace(text) ? text : null;
        }
        finally
        {
            if (copySequence is { } sequence && sequence == Native.GetClipboardSequenceNumber() &&
                ClipboardOwnedBy(processId) && OleSetClipboard(snapshot) == 0 && snapshot is not null)
                OleFlushClipboard();
        }
    }

    private static async Task<(uint? Sequence, string? Text)> ReadNewClipboardAsync(uint previous, nint window, uint processId)
    {
        uint? changed = null;
        var stableChecks = 0;
        for (var retry = 0; retry < 24; retry++)
        {
            await Task.Delay(25);
            var sequence = Native.GetClipboardSequenceNumber();
            if (Native.GetForegroundWindow() != window) return (changed, null);
            if (sequence == previous) continue;
            if (!ClipboardOwnedBy(processId)) return (null, null);
            if (sequence != changed)
            {
                changed = sequence;
                stableChecks = 0;
                continue;
            }
            if (++stableChecks < 2) continue;
            try
            {
                var text = Clipboard.GetText();
                var current = Native.GetClipboardSequenceNumber();
                // Reading a delayed-rendered format can advance its sequence number.
                return ClipboardOwnedBy(processId) ? (current, text) : (null, null);
            }
            catch (ExternalException) { }
        }
        return (changed, null);
    }

    private static bool ClipboardOwnedBy(uint processId)
    {
        var owner = Native.GetClipboardOwner();
        Native.GetWindowThreadProcessId(owner, out var ownerProcess);
        return owner != 0 && ownerProcess == processId;
    }

    private static bool ModifiersAreDown() => Native.IsDown(0x10) || Native.IsDown(0x11) ||
        Native.IsDown(0x12) || Native.IsDown(0x5B) || Native.IsDown(0x5C);

    [DllImport("ole32")] private static extern int OleGetClipboard([MarshalAs(UnmanagedType.Interface)] out DataObject? data);
    [DllImport("ole32")] private static extern int OleSetClipboard([MarshalAs(UnmanagedType.Interface)] DataObject? data);
    [DllImport("ole32")] private static extern int OleFlushClipboard();
}
