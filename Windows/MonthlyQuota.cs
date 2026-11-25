using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Luqri;

internal sealed class CloudRejectedException(string message) : InvalidOperationException(message);

internal sealed class MonthlyQuota(string filePrefix, string title, decimal limit, string unit)
{
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromMinutes(1);
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<string, State> states = new();
    private sealed record StoredUsage(string Month, decimal Used);

    private sealed class State(string path, string month, decimal used)
    {
        public string Path { get; } = path;
        public string Month { get; } = month;
        public decimal Used { get; set; } = used;
        public DateTimeOffset? RefreshedAt { get; set; }
    }

    public async Task<decimal> ReadAsync(Credentials credentials, DateTimeOffset now,
        Func<Credentials, DateTimeOffset, CancellationToken, Task<decimal>> query, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            var state = GetState(credentials, now);
            await RefreshAsync(state, credentials, now, query, token).ConfigureAwait(false);
            return state.Used;
        }
        finally { gate.Release(); }
    }

    public async Task<T> SendAsync<T>(Credentials credentials, int amount,
        Func<Credentials, DateTimeOffset, CancellationToken, Task<decimal>> query,
        Func<Task<T>> send, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            while (true)
            {
                var now = DateTimeOffset.UtcNow;
                var state = GetState(credentials, now);
                RequireCapacity(state.Used, amount);
                try { await RefreshAsync(state, credentials, now, query, token).ConfigureAwait(false); }
                catch (Exception error) when (!token.IsCancellationRequested)
                {
                    throw new InvalidOperationException($"无法确认{title}额度，已跳过请求。{error.Message}", error);
                }
                if (state.Month != CloudServices.BillingMonth(DateTimeOffset.UtcNow)) continue;
                token.ThrowIfCancellationRequested();
                RequireCapacity(state.Used, amount);

                var previous = state.Used;
                // Record the reservation before sending so delayed reports and app restarts cannot lose it.
                Store(state, previous + amount);
                try { return await send().ConfigureAwait(false); }
                catch (CloudRejectedException)
                {
                    Store(state, previous);
                    throw;
                }
            }
        }
        finally { gate.Release(); }
    }

    private void RequireCapacity(decimal used, int amount)
    {
        if (used >= limit)
            throw new InvalidOperationException($"{title}已达到本月免费额度（{limit:N0} {unit}），已跳过请求。");
        if (used + amount > limit)
            throw new InvalidOperationException($"本次请求超过{title}本月剩余额度（{limit - used:N0} {unit}），已跳过请求。");
    }

    private async Task RefreshAsync(State state, Credentials credentials, DateTimeOffset now,
        Func<Credentials, DateTimeOffset, CancellationToken, Task<decimal>> query, CancellationToken token)
    {
        if (state.RefreshedAt is { } refreshed && now >= refreshed && now - refreshed < RefreshInterval) return;
        var observed = await query(credentials, now, token).ConfigureAwait(false);
        if (observed > state.Used) Store(state, observed);
        state.RefreshedAt = now;
    }

    private State GetState(Credentials credentials, DateTimeOffset now)
    {
        var month = CloudServices.BillingMonth(now);
        var fingerprint = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(credentials.AccessKey)));
        var path = Preferences.QuotaPath($"{filePrefix}-{fingerprint}.usage.json");
        if (states.TryGetValue(path, out var current) && current.Month == month) return current;

        decimal used = 0;
        if (File.Exists(path))
        {
            var saved = JsonSerializer.Deserialize<StoredUsage>(File.ReadAllBytes(path))
                ?? throw new InvalidOperationException("本地用量记录无法读取。");
            if (saved.Month == month) used = Math.Max(0, saved.Used);
        }
        return states[path] = new(path, month, used);
    }

    private static void Store(State state, decimal used)
    {
        Preferences.WriteAtomically(state.Path, JsonSerializer.SerializeToUtf8Bytes(new StoredUsage(state.Month, used)));
        state.Used = used;
    }
}
