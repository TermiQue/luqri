using System.Net.Http;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Luqri;

internal sealed class VolcengineOcrUsage(
    Func<Credentials, DateTimeOffset, DateTimeOffset, CancellationToken, Task<Dictionary<string, DateTimeOffset>>> query)
{
    public const int Limit = 5000;
    private const int PendingLimit = 64;
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromMinutes(1);
    private static readonly TimeSpan CheckpointInterval = TimeSpan.FromDays(1);
    private static readonly TimeSpan AuditLookback = TimeSpan.FromDays(90) - TimeSpan.FromMinutes(5);
    private readonly SemaphoreSlim gate = new(1, 1);
    private State? activeState;

    private sealed record History(DateTimeOffset BeginsAt, DateTimeOffset? SynchronizedThrough,
        Dictionary<string, DateTimeOffset> Calls);

    private sealed class State(string path, History history, Dictionary<string, DateTimeOffset> pending)
    {
        public string Path { get; } = path;
        public History History { get; set; } = history;
        public DateTimeOffset? Checkpoint { get; private set; } = history.SynchronizedThrough;
        public Dictionary<string, DateTimeOffset> Pending { get; } = pending;
        public int Used => History.Calls.Count + Pending.Count;
        public DateTimeOffset? CheckedAt { get; set; }
        public Exception? AuditError { get; set; }

        public void SaveHistory(History updated)
        {
            Preferences.WriteAtomically(Path, JsonSerializer.SerializeToUtf8Bytes(updated));
            History = updated;
            Checkpoint = updated.SynchronizedThrough;
        }

        public void SavePending()
        {
            if (Pending.Count == 0) File.Delete(Path + ".pending");
            else Preferences.WriteAtomically(Path + ".pending", JsonSerializer.SerializeToUtf8Bytes(Pending));
        }

        public void Record(string id, DateTimeOffset time)
        {
            if (History.Calls.ContainsKey(id) || !Pending.TryAdd(id, time)) return;
            try { SavePending(); }
            catch { Pending.Remove(id); throw; }
            if (Pending.Count < PendingLimit) return;

            var calls = new Dictionary<string, DateTimeOffset>(History.Calls);
            foreach (var (requestId, sentAt) in Pending) calls[requestId] = sentAt;
            SaveHistory(History with { Calls = calls });
            Pending.Clear();
            SavePending();
        }
    }

    public async Task<decimal> ReadAsync(Credentials credentials, DateTimeOffset now, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            var state = GetState(credentials, now);
            await RefreshAsync(state, credentials, now, token).ConfigureAwait(false);
            if (state.History.SynchronizedThrough is null && state.AuditError is { } error)
                ExceptionDispatchInfo.Throw(error);
            return state.Used;
        }
        finally { gate.Release(); }
    }

    public async Task<string> SendAsync(Credentials credentials, Func<Task<(string? RequestId, string Text)>> send,
        CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            var now = DateTimeOffset.UtcNow;
            var state = GetState(credentials, now);
            RequireCapacity(state);
            await RefreshAsync(state, credentials, now, token).ConfigureAwait(false);
            RequireCapacity(state);
            token.ThrowIfCancellationRequested();

            var sentAt = CloudServices.BillingTime(DateTimeOffset.UtcNow);
            var (requestId, text) = await send().ConfigureAwait(false);
            if (!string.IsNullOrEmpty(requestId)) state.Record(requestId, sentAt);
            token.ThrowIfCancellationRequested();
            return text;
        }
        finally { gate.Release(); }
    }

    private static void RequireCapacity(State state)
    {
        if (state.Used >= Limit)
            throw new InvalidOperationException($"火山引擎 OCR 累计用量已达到 {Limit} 次，已跳过请求。");
    }

    private async Task RefreshAsync(State state, Credentials credentials, DateTimeOffset now, CancellationToken token)
    {
        if (state.CheckedAt is { } checkedAt && now >= checkedAt && now - checkedAt < RefreshInterval) return;

        var history = state.History;
        // Revisit recent events for delivery delays and replay missed time after a restart.
        var begin = history.SynchronizedThrough?.AddDays(-1) ?? history.BeginsAt;
        if (begin < history.BeginsAt) begin = history.BeginsAt;
        if (begin < now - AuditLookback) begin = now - AuditLookback;
        Dictionary<string, DateTimeOffset> observed;
        try { observed = await query(credentials, begin, now, token).ConfigureAwait(false); }
        catch (Exception error) when (!token.IsCancellationRequested &&
            error is CloudRejectedException or HttpRequestException or JsonException or OperationCanceledException)
        {
            // The local ledger still protects the known limit if audit access is unavailable.
            state.AuditError = error;
            state.CheckedAt = now;
            return;
        }
        token.ThrowIfCancellationRequested();
        Dictionary<string, DateTimeOffset>? updatedCalls = null;
        foreach (var (id, time) in observed)
        {
            if (history.Calls.TryGetValue(id, out var previous) && previous == time) continue;
            updatedCalls ??= new(history.Calls);
            updatedCalls[id] = time;
        }

        var updatedHistory = history with { Calls = updatedCalls ?? history.Calls, SynchronizedThrough = now };
        if (updatedCalls is not null || state.Checkpoint is not { } checkpoint || now - checkpoint >= CheckpointInterval)
            state.SaveHistory(updatedHistory);
        else state.History = updatedHistory;

        // The snapshot must be durable before clearing matching local records.
        // If interrupted between writes, loading the files merges by ID.
        var pendingChanged = false;
        foreach (var id in observed.Keys) pendingChanged |= state.Pending.Remove(id);
        if (pendingChanged) state.SavePending();
        state.AuditError = null;
        state.CheckedAt = now;
    }

    private State GetState(Credentials credentials, DateTimeOffset now)
    {
        var fingerprint = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(credentials.AccessKey)));
        var path = Preferences.QuotaPath($"volcengine-ocr-{fingerprint}.usage.json");
        if (activeState?.Path == path) return activeState;

        var pendingPath = path + ".pending";
        var pending = File.Exists(pendingPath)
            ? JsonSerializer.Deserialize<Dictionary<string, DateTimeOffset>>(File.ReadAllBytes(pendingPath))
                ?? throw new InvalidOperationException("本地火山引擎 OCR 待同步记录无法读取。")
            : new();
        if (File.Exists(path))
        {
            var history = JsonSerializer.Deserialize<History>(File.ReadAllBytes(path));
            if (history?.Calls is null || history.BeginsAt == default)
                throw new InvalidOperationException("本地火山引擎 OCR 用量记录无法读取。");
            foreach (var id in pending.Keys.ToArray())
                if (history.Calls.ContainsKey(id)) pending.Remove(id);
            return activeState = new(path, history, pending);
        }

        var initial = new History(CloudServices.BillingMonthStart(now), null, new());
        var state = new State(path, initial, pending);
        state.SaveHistory(initial);
        return activeState = state;
    }
}
