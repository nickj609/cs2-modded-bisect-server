using System.Security.Cryptography;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ServerBundleCheck;

// plugins.lock.json: which files each component installed and from which release. The updater removes a file only
// when the lock says the previous release of that component put it there.
public sealed class Lockfile
{
    public int Schema { get; set; } = 1;
    public SortedDictionary<string, LockEntry> Components { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static Lockfile Load(string path) =>
        File.Exists(path) ? JsonSerializer.Deserialize<Lockfile>(File.ReadAllText(path), Options) ?? new() : new();

    public void Save(string path) => File.WriteAllText(path, JsonSerializer.Serialize(this, Options) + "\n");

    // Record what is installed now, without a release behind it. Baseline files are never removed automatically:
    // nobody knows whether the plugin or an admin put them there.
    public static Lockfile Baseline(Bundle b)
    {
        var lf = new Lockfile();
        foreach (var c in b.Manifest.Components)
            lf.Components[c.Name] = new LockEntry
            {
                Version = c.Version,
                Baseline = true,
                Files = new SortedDictionary<string, string>(
                    OwnedFiles(b, c).Distinct(StringComparer.OrdinalIgnoreCase).ToDictionary(f => f, f => Hash(b.Full(f)), StringComparer.OrdinalIgnoreCase),
                    StringComparer.OrdinalIgnoreCase),
            };
        return lf;
    }

    // Files under the component's paths that the component owns (the most specific owner wins).
    public static IEnumerable<string> OwnedFiles(Bundle b, Component c)
    {
        foreach (string p in c.Paths)
        {
            string full = b.Full(p);
            IEnumerable<string> files = p.EndsWith('/')
                ? (Directory.Exists(full) ? Directory.EnumerateFiles(full, "*", SearchOption.AllDirectories) : Enumerable.Empty<string>())
                : (File.Exists(full) ? new[] { full } : Enumerable.Empty<string>());
            foreach (string f in files)
            {
                string rel = b.Rel(f);
                if (b.Owner(rel) == c) yield return rel;
            }
        }
    }

    // First 16 hex chars of SHA-256: enough to notice a changed file, keeps the lock small.
    public static string Hash(string fullPath)
    {
        using var s = File.OpenRead(fullPath);
        return Convert.ToHexString(SHA256.HashData(s))[..16].ToLowerInvariant();
    }
}

public sealed class LockEntry
{
    public string Version { get; set; } = "";
    public string? Asset { get; set; }
    public string? Url { get; set; }
    public DateTime? Installed { get; set; }

    // true: recorded from the repo, not installed by the updater.
    public bool Baseline { get; set; }
    public SortedDictionary<string, string> Files { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}
