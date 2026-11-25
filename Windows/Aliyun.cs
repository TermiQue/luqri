using System.Globalization;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Media.Imaging;

namespace Luqri;

internal sealed class Aliyun(HttpClient client) : ICloudService
{
    private sealed record Operation(string Host, string Action, string Version);

    private static readonly Operation Translation = new("mt.aliyuncs.com", "TranslateGeneral", "2018-10-12");
    private static readonly Operation Report = Translation with { Action = "GetTranslateReport" };
    private static readonly Operation Ocr = new("ocr-api.cn-hangzhou.aliyuncs.com", "RecognizeMultiLanguage", "2021-07-07");
    private const string Languages = "chn,eng,ja,kor,lading,rus,tai,mys,idn,viet,ukr,tur,tamil";
    private const string ReportDateFormat = "yyyy-MM-dd HH:mm:ss";
    public const decimal FreeCharacters = 1_000_000;

    public async Task<string> TranslateAsync(string text, TranslationLanguage? source, TranslationLanguage target,
        Credentials credentials, CancellationToken token)
    {
        var sourceCode = source is null ? "auto" : LanguageCode(source);
        var targetCode = LanguageCode(target);
        // The service documents Traditional Chinese pairs via Simplified Chinese.
        if ((sourceCode == "zh-tw" && targetCode is not ("zh" or "zh-tw")) ||
            (targetCode == "zh-tw" && sourceCode is not ("zh" or "zh-tw")))
        {
            text = await TranslateChunksAsync(text, sourceCode, "zh", credentials, token).ConfigureAwait(false);
            sourceCode = "zh";
        }
        return await TranslateChunksAsync(text, sourceCode, targetCode, credentials, token).ConfigureAwait(false);
    }

    private async Task<string> TranslateChunksAsync(string text, string source, string target,
        Credentials credentials, CancellationToken token)
    {
        if (source == target) return text;
        var result = new StringBuilder();
        foreach (var chunk in CloudServices.TextChunks(text, 4999))
        {
            token.ThrowIfCancellationRequested();
            var content = chunk.Trim();
            if (content.Length == 0)
            {
                result.Append(chunk);
                continue;
            }

            var translated = await TranslatePartAsync(content, source, target, credentials, token).ConfigureAwait(false);
            var start = chunk.IndexOf(content, StringComparison.Ordinal);
            result.Append(chunk.AsSpan(0, start));
            result.Append(translated);
            result.Append(chunk.AsSpan(start + content.Length));
        }
        return result.ToString();
    }

    private async Task<string> TranslatePartAsync(string text, string source, string target,
        Credentials credentials, CancellationToken token)
    {
        using var content = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["FormatType"] = "text", ["Scene"] = "general", ["SourceLanguage"] = source,
            ["TargetLanguage"] = target, ["SourceText"] = text
        });
        var body = await content.ReadAsByteArrayAsync(token).ConfigureAwait(false);
        using var response = await SendAsync(Translation, HttpMethod.Post, null, body,
            "application/x-www-form-urlencoded", credentials, token).ConfigureAwait(false);
        var data = RequireTranslationData(response.RootElement);
        return String(data, "Translated") is { Length: > 0 } translated ? translated
            : throw new InvalidOperationException("阿里云未返回译文。");
    }

    public async Task<decimal> ReadUsageAsync(Credentials credentials, DateTimeOffset now, CancellationToken token)
    {
        var end = CloudServices.BillingTime(now);
        var begin = new DateTimeOffset(end.Year, end.Month, 1, 0, 0, 0, end.Offset);
        var parameters = new Dictionary<string, string>
        {
            ["ApiName"] = "translate_standard", ["Group"] = "day",
            ["BeginTime"] = begin.ToString(ReportDateFormat, CultureInfo.InvariantCulture),
            ["EndTime"] = end.ToString(ReportDateFormat, CultureInfo.InvariantCulture)
        };
        using var response = await SendAsync(Report, HttpMethod.Get, parameters, [], null, credentials, token).ConfigureAwait(false);
        using var report = ParseEmbeddedData(RequireTranslationData(response.RootElement));
        var rows = Field(report.RootElement, "result");
        if (rows.ValueKind != JsonValueKind.Array) throw new JsonException("Missing report rows.");

        decimal total = 0;
        foreach (var row in rows.EnumerateArray())
        {
            if (!decimal.TryParse(Scalar(row, "total"), NumberStyles.Float, CultureInfo.InvariantCulture, out var count) || count < 0)
                throw new JsonException("Invalid report total.");
            total += count;
        }
        return total;
    }

    public async Task<string> RecognizeAsync(BitmapSource image, Credentials credentials, CancellationToken token)
    {
        var body = await Task.Run(() => OcrImage.EncodeAliyun(image, token), token).ConfigureAwait(false);
        var parameters = new Dictionary<string, string> { ["Languages"] = Languages };
        using var response = await SendAsync(Ocr, HttpMethod.Post, parameters, body,
            "application/octet-stream", credentials, token).ConfigureAwait(false);
        var root = response.RootElement;
        if (Scalar(root, "Code") is { Length: > 0 } code && code is not ("200" or "Success"))
            throw ServiceError(root, code);

        using var data = ParseEmbeddedData(Field(root, "Data"));
        var blocks = Field(data.RootElement, "prism_wordsInfo");
        var text = blocks.ValueKind == JsonValueKind.Array
            ? OcrLine.Paragraphs(blocks.EnumerateArray()
                .Select(block => new OcrLine(String(block, "word")?.Trim() ?? "", Bounds(Field(block, "pos"))))
                .Where(line => line.Text.Length > 0))
            : "";
        if (text.Length == 0) text = String(data.RootElement, "content")?.Trim() ?? "";
        return text.Length > 0 ? text : throw new InvalidOperationException("选区中没有识别到文字。");
    }

    private static Rect Bounds(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() != 4) return Rect.Empty;
        var bounds = Rect.Empty;
        foreach (var corner in value.EnumerateArray())
        {
            var x = Field(corner, "x");
            var y = Field(corner, "y");
            if (x.ValueKind != JsonValueKind.Number || y.ValueKind != JsonValueKind.Number ||
                !x.TryGetDouble(out var left) || !y.TryGetDouble(out var top) ||
                !double.IsFinite(left) || !double.IsFinite(top)) return Rect.Empty;
            bounds.Union(new Point(left, top));
        }
        return bounds;
    }

    private async Task<JsonDocument> SendAsync(Operation operation, HttpMethod method, Dictionary<string, string>? parameters,
        byte[] body, string? contentType, Credentials credentials, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        using var request = Sign(operation, method, parameters, body, contentType, credentials);
        using var response = await client.SendAsync(request, token).ConfigureAwait(false);
        var bytes = await response.Content.ReadAsByteArrayAsync(token).ConfigureAwait(false);
        if (response.IsSuccessStatusCode) return JsonDocument.Parse(bytes);

        try
        {
            using var details = JsonDocument.Parse(bytes);
            if (Scalar(details.RootElement, "Code") is { Length: > 0 } code) throw ServiceError(details.RootElement, code);
        }
        catch (JsonException) { }
        throw new InvalidOperationException($"阿里云请求失败（HTTP {(int)response.StatusCode}）。");
    }

    private static HttpRequestMessage Sign(Operation operation, HttpMethod method, Dictionary<string, string>? parameters,
        byte[] body, string? contentType, Credentials credentials)
    {
        const string algorithm = "ACS3-HMAC-SHA256";
        var query = parameters is null ? "" : string.Join("&", parameters
            .Select(pair => (Key: Uri.EscapeDataString(pair.Key), Value: Uri.EscapeDataString(pair.Value)))
            .OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => $"{pair.Key}={pair.Value}"));
        var payloadHash = Convert.ToHexStringLower(SHA256.HashData(body));
        var headers = new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
            ["host"] = operation.Host,
            ["x-acs-action"] = operation.Action,
            ["x-acs-content-sha256"] = payloadHash,
            ["x-acs-date"] = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
            ["x-acs-signature-nonce"] = Guid.NewGuid().ToString("N"),
            ["x-acs-version"] = operation.Version
        };
        if (contentType is not null) headers["content-type"] = contentType;

        var signedHeaders = string.Join(";", headers.Keys);
        var canonicalHeaders = string.Concat(headers.Select(pair => $"{pair.Key}:{pair.Value}\n"));
        var canonicalRequest = $"{method.Method}\n/\n{query}\n{canonicalHeaders}\n{signedHeaders}\n{payloadHash}";
        var requestHash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonicalRequest)));
        var key = Encoding.UTF8.GetBytes(credentials.SecretKey);
        string signature;
        try
        {
            signature = Convert.ToHexStringLower(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes($"{algorithm}\n{requestHash}")));
        }
        finally { CryptographicOperations.ZeroMemory(key); }

        var request = new HttpRequestMessage(method, $"https://{operation.Host}/" + (query.Length == 0 ? "" : "?" + query));
        if (contentType is not null)
        {
            request.Content = new ByteArrayContent(body);
            request.Content.Headers.ContentType = new(contentType);
        }
        foreach (var (name, value) in headers)
            if (name != "content-type") request.Headers.TryAddWithoutValidation(name, value);
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.TryAddWithoutValidation("Authorization",
            $"{algorithm} Credential={credentials.AccessKey},SignedHeaders={signedHeaders},Signature={signature}");
        return request;
    }

    private static string LanguageCode(TranslationLanguage language) => language.Code == "zh-Hant" ? "zh-tw" : language.CloudCode;

    private static JsonElement RequireTranslationData(JsonElement response)
    {
        var code = Scalar(response, "Code");
        if (code != "200") throw code is null ? new JsonException("Missing translation response code.") : ServiceError(response, code);
        return Field(response, "Data");
    }

    private static InvalidOperationException ServiceError(JsonElement response, string code) =>
        new($"阿里云返回 {code} · {String(response, "Message") ?? "请求失败。"}");

    private static JsonDocument ParseEmbeddedData(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => JsonDocument.Parse(value.GetString()!),
        JsonValueKind.Object => JsonDocument.Parse(value.GetRawText()),
        _ => throw new JsonException("Missing response data.")
    };

    private static JsonElement Field(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var field) ? field : default;

    private static string? String(JsonElement value, string name)
    {
        var field = Field(value, name);
        return field.ValueKind == JsonValueKind.String ? field.GetString() : null;
    }

    private static string? Scalar(JsonElement value, string name)
    {
        var field = Field(value, name);
        return field.ValueKind == JsonValueKind.Number ? field.GetRawText() : String(value, name);
    }
}
