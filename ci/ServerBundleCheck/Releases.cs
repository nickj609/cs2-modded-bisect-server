using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ServerBundleCheck;

public sealed record ReleaseAsset(string Name, string Url, long Size);

public sealed record Release(string Tag, string HtmlUrl, List<ReleaseAsset> Assets, string? Repo);

// Finds the latest release of a component. GitHub answers are cached on disk so repeated runs don't spend the
// API limit (60 requests/hour without a token, 5000 with GITHUB_TOKEN).
public sealed class Releases : IDisposable
{
    private readonly HttpClient _http;
    private readonly string? _cacheDir;
    private readonly TimeSpan _cacheTtl;
    public bool RateLimited { get; private set; }

    public Releases(string? cacheDir, TimeSpan cacheTtl)
    {
        _cacheDir = cacheDir;
        _cacheTtl = cacheTtl;
        _http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = true });
        _http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("cs2-modded-bisect-server-updater", "1.0"));
        string? token = Environment.GetEnvironmentVariable("GITHUB_TOKEN") ?? Environment.GetEnvironmentVariable("GH_TOKEN");
        if (!string.IsNullOrEmpty(token))
            _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (_cacheDir != null) Directory.CreateDirectory(_cacheDir);
    }

    public HttpClient Http => _http;

    // null + error when the release can't be found.
    public async Task<(Release? Release, string? Error)> LatestAsync(Source source)
    {
        if (source.Github != null) return await GitHubAsync(source.Github);
        if (source.Url != null) return await PageAsync(source.Url, source.Pattern);
        return (null, "no source");
    }

    private async Task<(Release?, string?)> GitHubAsync(string repo)
    {
        string? json = ReadCache(repo);
        if (json == null)
        {
            if (RateLimited) return (null, "GitHub API rate limit reached (set GITHUB_TOKEN)");
            using var req = new HttpRequestMessage(HttpMethod.Get, $"https://api.github.com/repos/{repo}/releases/latest");
            req.Headers.Accept.ParseAdd("application/vnd.github+json");
            using var res = await _http.SendAsync(req);
            json = await res.Content.ReadAsStringAsync();
            if (res.StatusCode == HttpStatusCode.Forbidden || (int)res.StatusCode == 429)
            {
                RateLimited = true;
                return (null, "GitHub API rate limit reached (set GITHUB_TOKEN)");
            }
            if (res.StatusCode == HttpStatusCode.NotFound) return (null, "no releases (or the repository doesn't exist)");
            if (!res.IsSuccessStatusCode) return (null, $"GitHub API {(int)res.StatusCode}");
            WriteCache(repo, json);
        }

        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (!root.TryGetProperty("tag_name", out var tag))
        {
            string msg = root.TryGetProperty("message", out var m) ? m.GetString() ?? "" : "";
            return (null, msg == "Not Found" ? "no releases (or the repository doesn't exist)" : $"unexpected answer: {msg}");
        }
        var assets = new List<ReleaseAsset>();
        if (root.TryGetProperty("assets", out var arr))
            foreach (var a in arr.EnumerateArray())
                assets.Add(new ReleaseAsset(a.GetProperty("name").GetString()!, a.GetProperty("browser_download_url").GetString()!, a.GetProperty("size").GetInt64()));

        // The repo may have moved; html_url carries the current owner/name.
        string html = root.TryGetProperty("html_url", out var h) ? h.GetString() ?? "" : "";
        var moved = Regex.Match(html, @"github\.com/([^/]+/[^/]+)/releases");
        string? current = moved.Success ? moved.Groups[1].Value : null;
        return (new Release(tag.GetString()!, html, assets, current), null);
    }

    // A download page (Metamod:Source): the first link matching the pattern; group "version" is the version.
    private async Task<(Release?, string?)> PageAsync(string url, string? pattern)
    {
        if (pattern == null) return (null, "url source needs a pattern");
        string html;
        try { html = await _http.GetStringAsync(url); }
        catch (Exception e) { return (null, $"download page: {e.Message}"); }
        var m = Regex.Match(html, pattern);
        if (!m.Success) return (null, "pattern matched nothing on the download page");
        string link = WebUtility.HtmlDecode(m.Value);
        if (!link.StartsWith("http")) link = new Uri(new Uri(url), link).ToString();
        string version = m.Groups["version"].Success ? m.Groups["version"].Value : link;
        return (new Release(version, url, new List<ReleaseAsset> { new(Path.GetFileName(new Uri(link).LocalPath), link, 0) }, null), null);
    }

    private string CacheFile(string repo) => Path.Combine(_cacheDir!, repo.Replace('/', '_').Replace('\\', '_') + ".json");

    private string? ReadCache(string repo)
    {
        if (_cacheDir == null) return null;
        string f = CacheFile(repo);
        if (!File.Exists(f) || DateTime.UtcNow - File.GetLastWriteTimeUtc(f) > _cacheTtl) return null;
        string json = File.ReadAllText(f);
        return json.Contains("\"tag_name\"") ? json : null;   // don't trust cached errors
    }

    private void WriteCache(string repo, string json)
    {
        if (_cacheDir != null) File.WriteAllText(CacheFile(repo), json);
    }

    public void Dispose() => _http.Dispose();
}
