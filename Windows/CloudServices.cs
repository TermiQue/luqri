using System.Net.Http;
using System.Text.Json;
using System.Windows.Media.Imaging;

namespace Luqri;

internal enum CloudProvider { Volcengine, Aliyun }

internal interface ICloudService
{
    Task<string> TranslateAsync(string text, TranslationLanguage? source, TranslationLanguage target,
        Credentials credentials, CancellationToken token);
    Task<string> RecognizeAsync(BitmapSource image, Credentials credentials, CancellationToken token);
    Task<decimal> ReadUsageAsync(Credentials credentials, DateTimeOffset now, CancellationToken token);
}

internal sealed class CloudServices(HttpClient client)
{
    public static readonly CloudProvider[] Providers = [CloudProvider.Volcengine, CloudProvider.Aliyun];
    private readonly Volcengine volcengine = new(client);
    private readonly Aliyun aliyun = new(client);

    public ICloudService this[CloudProvider provider] => provider == CloudProvider.Aliyun ? aliyun : volcengine;

    public Task<decimal> ReadAliyunOcrUsageAsync(Credentials credentials, DateTimeOffset now, CancellationToken token) =>
        aliyun.ReadOcrUsageAsync(credentials, now, token);

    public static string Name(CloudProvider provider) => provider == CloudProvider.Aliyun ? "阿里云" : "火山引擎";

    public static DateTimeOffset BillingTime(DateTimeOffset time) => time.ToOffset(TimeSpan.FromHours(8));

    public static string DescribeError(CloudProvider provider, Exception error) => error switch
    {
        OperationCanceledException => "请求超时，请重试。",
        HttpRequestException => $"无法连接{Name(provider)}，请检查网络后重试。",
        JsonException => $"{Name(provider)}返回格式异常，请重试。",
        _ => error.Message
    };

    public static IEnumerable<string> TextChunks(string text, int limit)
    {
        var start = 0;
        while (text.Length - start > limit)
        {
            var end = start + limit;
            if (char.IsLowSurrogate(text[end])) end--;
            for (var index = end - 1; index >= start + limit / 2; index--)
            {
                if (!"\n\r 。！？".Contains(text[index])) continue;
                end = index + 1;
                break;
            }
            yield return text[start..end];
            start = end;
        }
        yield return text[start..];
    }
}
