using System.Globalization;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Media.Imaging;
using static Luqri.CloudJson;

namespace Luqri;

internal sealed class Volcengine : ICloudService
{
    private sealed record Operation(string Host, string Action, string Version, string Service,
        string ContentType = "application/json")
    {
        public string Query { get; } = $"Action={Action}&Version={Version}";
    }

    private static readonly Operation Translation = new("translate.volcengineapi.com", "TranslateText", "2020-06-01", "translate");
    private static readonly Operation Ocr = new("visual.volcengineapi.com", "MultiLanguageOCR", "2022-08-31", "cv", "application/x-www-form-urlencoded");
    private static readonly Operation OcrAudit = new("open.volcengineapi.com", "LookupEvents", "2021-09-01", "cloud_trail");
    private static readonly Operation Billing = new("open.volcengineapi.com", "ListBillDetail", "2022-01-01", "billing");
    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };
    public const decimal FreeCharacters = 2_000_000;
    private readonly HttpClient client;
    private readonly MonthlyQuota translationQuota = new("volcengine-translate", "火山引擎机器翻译", FreeCharacters, "字符");
    private readonly VolcengineOcrUsage ocrUsage;

    public Volcengine(HttpClient client)
    {
        this.client = client;
        ocrUsage = new(QueryOcrUsageAsync);
    }

    public async Task<string> TranslateAsync(string text, TranslationLanguage? source, TranslationLanguage target, Credentials credentials, CancellationToken token)
    {
        var result = new StringBuilder();
        var sourceCode = source?.CloudCode;
        foreach (var chunk in CloudServices.TextChunks(text, 5000))
        {
            token.ThrowIfCancellationRequested();
            var content = chunk.Trim();
            if (content.Length == 0)
            {
                result.Append(chunk);
                continue;
            }

            var payload = JsonSerializer.SerializeToUtf8Bytes(new
            {
                SourceLanguage = sourceCode, TargetLanguage = target.CloudCode, TextList = new[] { content }
            }, Json);
            using var response = await translationQuota.SendAsync(credentials, content.Length, QueryUsageAsync,
                () => SendAsync(Translation, payload, credentials, token), token).ConfigureAwait(false);
            var list = Field(response.RootElement, "TranslationList");
            if (list.ValueKind != JsonValueKind.Array || list.GetArrayLength() == 0 ||
                String(list[0], "Translation") is not { Length: > 0 } translated)
                throw new InvalidOperationException("火山引擎未返回译文。");

            var start = chunk.IndexOf(content, StringComparison.Ordinal);
            result.Append(chunk.AsSpan(0, start));
            result.Append(translated);
            result.Append(chunk.AsSpan(start + content.Length));
            sourceCode ??= String(list[0], "DetectedSourceLanguage");
        }
        return result.ToString();
    }

    public async Task<string> RecognizeAsync(BitmapSource image, Credentials credentials, CancellationToken token)
    {
        var text = await ocrUsage.SendAsync(credentials, () => RecognizeImageAsync(image, credentials, token), token)
            .ConfigureAwait(false);
        return text.Length > 0 ? text : throw new InvalidOperationException("选区中没有识别到文字。");
    }

    private async Task<(string? RequestId, string Text)> RecognizeImageAsync(BitmapSource image, Credentials credentials,
        CancellationToken token)
    {
        var payload = await Task.Run(() => OcrImage.Encode(image, token), token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        // Keep the response after dispatch even if the caller moves on, so the accepted request can be counted.
        using var response = await SendAsync(Ocr, payload, credentials, CancellationToken.None).ConfigureAwait(false);
        var root = response.RootElement;
        var codes = new[] { Field(root, "code"), Field(root, "status") }
            .Where(value => value.ValueKind == JsonValueKind.Number).Select(value => value.GetInt32()).ToArray();
        foreach (var code in codes)
            if (code != 10000) throw new InvalidOperationException($"火山引擎返回 {code} · {String(root, "message") ?? "OCR 请求失败。"}");

        var lines = Field(Field(root, "data"), "ocr_infos");
        if (codes.Length == 0 || lines.ValueKind != JsonValueKind.Array)
            throw new InvalidOperationException("火山引擎 OCR 返回格式异常，请重试。");

        var text = OcrLine.Paragraphs(lines.EnumerateArray()
            .Select(line => new OcrLine(String(line, "text")?.Trim() ?? "", Bounds(Field(line, "rect"))))
            .Where(line => line.Text.Length > 0));
        return (String(root, "request_id"), text);
    }

    private static Rect Bounds(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() != 4) return Rect.Empty;
        var bounds = Rect.Empty;
        foreach (var pair in value.EnumerateArray())
        {
            if (pair.ValueKind != JsonValueKind.Array || pair.GetArrayLength() != 2 ||
                pair[0].ValueKind != JsonValueKind.Number || pair[1].ValueKind != JsonValueKind.Number ||
                !pair[0].TryGetDouble(out var x) || !pair[1].TryGetDouble(out var y) ||
                !double.IsFinite(x) || !double.IsFinite(y)) return Rect.Empty;
            bounds.Union(new Point(x, y));
        }
        return bounds;
    }

    public Task<decimal> ReadTranslationUsageAsync(Credentials credentials, DateTimeOffset now, CancellationToken token) =>
        translationQuota.ReadAsync(credentials, now, QueryUsageAsync, token);

    public Task<decimal> ReadOcrUsageAsync(Credentials credentials, DateTimeOffset now, CancellationToken token) =>
        ocrUsage.ReadAsync(credentials, now, token);

    private async Task<Dictionary<string, DateTimeOffset>> QueryOcrUsageAsync(Credentials credentials,
        DateTimeOffset begin, DateTimeOffset end, CancellationToken token)
    {
        var calls = new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal);
        var startTime = begin.ToUnixTimeSeconds();
        var endTime = end.ToUnixTimeSeconds();
        if (startTime >= endTime) return calls;

        string? cursor = null;
        var cursors = new HashSet<string>(StringComparer.Ordinal);
        while (true)
        {
            var body = JsonSerializer.SerializeToUtf8Bytes(new
            {
                StartTime = startTime, EndTime = endTime, MaxResults = 100, NextToken = cursor,
                LookupConditions = new[]
                {
                    new { LookupConditionKey = "EventName", LookupConditionValue = Ocr.Action },
                    new { LookupConditionKey = "EventSource", LookupConditionValue = Ocr.Service }
                }
            }, Json);
            using var response = await SendAsync(OcrAudit, body, credentials, token).ConfigureAwait(false);
            var result = Field(response.RootElement, "Result");
            var trails = Field(result, "Trails");
            cursor = String(result, "NextToken");
            if (trails.ValueKind == JsonValueKind.Array)
            {
                foreach (var record in trails.EnumerateArray())
                {
                    if (String(record, "EventName") != Ocr.Action || String(record, "EventSource") != Ocr.Service ||
                        String(record, "ErrorCode") is { Length: > 0 }) continue;
                    if (String(record, "RequestID") is not { Length: > 0 } id ||
                        !DateTimeOffset.TryParse(String(record, "EventTime"), CultureInfo.InvariantCulture,
                            DateTimeStyles.None, out var time))
                        throw new JsonException("Missing OCR audit request ID or timestamp.");
                    if (time.ToUnixTimeSeconds() >= startTime && time.ToUnixTimeSeconds() <= endTime)
                        calls[id] = CloudServices.BillingTime(time);
                }
            }
            else if (result.ValueKind != JsonValueKind.Object || trails.ValueKind != JsonValueKind.Null ||
                !string.IsNullOrEmpty(cursor))
                throw new JsonException("Missing OCR audit events.");

            if (string.IsNullOrEmpty(cursor)) return calls;
            if (!cursors.Add(cursor)) throw new JsonException("Repeated OCR audit page.");
            await Task.Delay(250, token).ConfigureAwait(false);
        }
    }

    private async Task<decimal> QueryUsageAsync(Credentials credentials, DateTimeOffset now, CancellationToken token)
    {
        const int pageSize = 100;
        var month = CloudServices.BillingMonth(now);
        decimal total = 0;
        for (var offset = 0; ; offset += pageSize)
        {
            var body = JsonSerializer.SerializeToUtf8Bytes(new
            {
                BillPeriod = month, GroupTerm = 0, GroupPeriod = 1, IgnoreZero = 0, Limit = pageSize, Offset = offset
            });
            using var response = await SendAsync(Billing, body, credentials, token).ConfigureAwait(false);
            var result = Field(response.RootElement, "Result");
            var entries = Field(result, "List");
            if (result.ValueKind != JsonValueKind.Object) throw InvalidBillingResult();
            if (entries.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return Math.Max(0, total);
            if (entries.ValueKind != JsonValueKind.Array) throw InvalidBillingResult();
            foreach (var entry in entries.EnumerateArray()) total += TranslationCharacters(entry);
            if (entries.GetArrayLength() < pageSize) return Math.Max(0, total);
        }
    }

    private static decimal TranslationCharacters(JsonElement row)
    {
        var labels = new[] { "ProductZh", "Product", "ConfigName", "Element", "Unit" }
            .Select(name => String(row, name)?.Trim() ?? "").ToArray();
        var multiplier = labels[4] switch
        {
            "字符" or "字符数" => 1,
            "千字符" or "千字符数" => 1000,
            "万字符" or "万字符数" => 10000,
            "百万字符" or "百万字符数" => 1000000,
            "" when labels[3] == "百万字符数" => 1000000,
            _ => 0
        };
        var matchesTranslation = labels.Take(3).Contains("机器翻译接口服务") ||
            labels.Take(4).Any(label => Regex.IsMatch(label, @"文本翻译|text[\s_-]*translation|TranslateText", RegexOptions.IgnoreCase)) ||
            (labels.Take(2).Contains("机器翻译") && (labels[3] == "百万字符数" || multiplier > 0));
        if (!matchesTranslation) return 0;
        var field = Field(row, "Count");
        if (field.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return 0;
        var number = field.ValueKind == JsonValueKind.String ? field.GetString()?.Trim() : field.GetRawText();
        if (number is "" or "-") return 0;
        if (multiplier == 0 || !decimal.TryParse(number, NumberStyles.Float, CultureInfo.InvariantCulture, out var count))
            throw InvalidBillingResult();
        return count * multiplier;
    }

    private static InvalidOperationException InvalidBillingResult() => new("火山引擎返回的账单明细无法计算用量。");

    private async Task<JsonDocument> SendAsync(Operation operation, byte[] payload, Credentials credentials, CancellationToken token)
    {
        using var request = Sign(operation, payload, credentials, DateTimeOffset.UtcNow);
        using var response = await client.SendAsync(request, token).ConfigureAwait(false);
        var bytes = await response.Content.ReadAsByteArrayAsync(token).ConfigureAwait(false);
        JsonDocument? result = null;
        try
        {
            try { result = JsonDocument.Parse(bytes); }
            catch (JsonException) when (!response.IsSuccessStatusCode) { }
            var error = result is null ? default : Field(Field(result.RootElement, "ResponseMetadata"), "Error");
            if (String(error, "Code") is { } code)
                throw new CloudRejectedException($"火山引擎返回 {code} · {String(error, "Message")}");
            if (!response.IsSuccessStatusCode)
                throw (int)response.StatusCode < 500
                    ? new CloudRejectedException($"火山引擎请求失败（HTTP {(int)response.StatusCode}）。")
                    : new InvalidOperationException($"火山引擎请求失败（HTTP {(int)response.StatusCode}）。");
            return result!;
        }
        catch
        {
            result?.Dispose();
            throw;
        }
    }

    private static HttpRequestMessage Sign(Operation operation, byte[] payload, Credentials credentials, DateTimeOffset now)
    {
        var timestamp = now.UtcDateTime.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        var scopeParts = new[] { timestamp[..8], "cn-north-1", operation.Service, "request" };
        var scope = string.Join("/", scopeParts);
        var hash = Convert.ToHexStringLower(SHA256.HashData(payload));
        const string signedHeaders = "content-type;host;x-content-sha256;x-date";
        var headers = $"content-type:{operation.ContentType}\nhost:{operation.Host}\nx-content-sha256:{hash}\nx-date:{timestamp}\n";
        var canonical = $"POST\n/\n{operation.Query}\n{headers}\n{signedHeaders}\n{hash}";
        var requestHash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
        var toSign = $"HMAC-SHA256\n{timestamp}\n{scope}\n{requestHash}";
        var key = Encoding.UTF8.GetBytes(credentials.SecretKey);
        foreach (var part in scopeParts) key = HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(part));
        var signature = Convert.ToHexStringLower(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(toSign)));

        var request = new HttpRequestMessage(HttpMethod.Post, $"https://{operation.Host}/?{operation.Query}")
        {
            Content = new ByteArrayContent(payload)
        };
        request.Content.Headers.ContentType = new(operation.ContentType);
        request.Headers.Host = operation.Host;
        request.Headers.TryAddWithoutValidation("X-Content-Sha256", hash);
        request.Headers.TryAddWithoutValidation("X-Date", timestamp);
        request.Headers.TryAddWithoutValidation("Authorization",
            $"HMAC-SHA256 Credential={credentials.AccessKey}/{scope}, SignedHeaders={signedHeaders}, Signature={signature}");
        return request;
    }
}
