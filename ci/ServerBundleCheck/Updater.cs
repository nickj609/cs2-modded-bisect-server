using System.Formats.Tar;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace ServerBundleCheck;

public sealed class UpdateOptions
{
    public bool DryRun { get; init; }
    public bool NoDownload { get; init; }        // only compare versions
    public string? Only { get; init; }           // one component by name
    public string WorkDir { get; init; } = Path.Combine(Path.GetTempPath(), "cs2-plugin-updates");
    public string? SummaryPath { get; init; }

    // Also remove files recorded by 'lock --init' that an updated component's new release doesn't ship.
    // Without it those are only listed: nobody knows who put them there.
    public bool Prune { get; init; }

    // Install a local build instead of the latest release (needs Only and FromZipVersion): a test build goes through
    // the same mapping, placement rules and lock as a release of that component.
    public string? FromZip { get; init; }
    public string? FromZipVersion { get; init; }
}

public sealed class PlanItem
{
    public required Component Component { get; init; }
    public string Status { get; set; } = "";     // current | update | pinned | skipped | error
    public string? Latest { get; set; }
    public ReleaseAsset? Asset { get; set; }
    public string? Repo { get; set; }
    public List<string> Notes { get; } = new();
    public int Added, Changed, Removed, Unchanged;
    public List<string> PossiblyStale { get; } = new();

    // Files in the release that no path of the component maps to (paths inside the archive).
    public List<string> NotInstalled { get; } = new();
}

// Finds new releases, maps their files onto game/csgo, and (unless dry run) writes them, plugins.lock.json and the
// version in plugins.yaml. Nothing is deployed: the result is a change in the repo to review and merge.
public sealed class Updater
{
    private readonly Bundle _b;
    private readonly Lockfile _lock;
    private readonly string _lockPath, _manifestPath;
    private readonly UpdateOptions _o;
    private readonly HashSet<string> _sharedNames;

    public Updater(Bundle bundle, string manifestPath, string lockPath, UpdateOptions options)
    {
        _b = bundle;
        _manifestPath = manifestPath;
        _lockPath = lockPath;
        _o = options;
        _lock = Lockfile.Load(lockPath);
        _sharedNames = bundle.SharedAssemblyNames().ToHashSet(StringComparer.OrdinalIgnoreCase);
    }

    public async Task<List<PlanItem>> RunAsync()
    {
        if (_lock.Components.Count == 0)
            throw new InvalidOperationException("plugins.lock.json is missing or empty. Run 'ServerBundleCheck lock --init' first.");

        var items = new List<PlanItem>();
        using var releases = new Releases(Path.Combine(_o.WorkDir, "api"), TimeSpan.FromHours(6));
        foreach (var c in _b.Manifest.Components)
        {
            if (_o.Only != null && !c.Name.Equals(_o.Only, StringComparison.OrdinalIgnoreCase)) continue;
            var item = new PlanItem { Component = c };
            items.Add(item);

            if (_o.FromZip != null)
            {
                item.Latest = _o.FromZipVersion;
                item.Asset = new ReleaseAsset(Path.GetFileName(_o.FromZip), "local build", new FileInfo(_o.FromZip).Length);
                item.Status = "update";
                try { await ApplyAsync(item, releases.Http); }
                catch (Exception e)
                {
                    item.Status = "error";
                    item.Notes.Add(e.Message);
                }
                continue;
            }

            if (c.Source == null || (c.Source.Github == null && c.Source.Url == null)) { item.Status = "skipped"; item.Notes.Add("no source"); continue; }

            var (release, error) = await releases.LatestAsync(c.Source);
            if (release == null) { item.Status = "error"; item.Notes.Add(error!); continue; }
            item.Latest = release.Tag;
            item.Repo = release.Repo;
            if (release.Repo != null && c.Source.Github != null && !release.Repo.Equals(c.Source.Github, StringComparison.OrdinalIgnoreCase))
                item.Notes.Add($"repository moved to {release.Repo}");

            if (SameVersion(c.Version, release.Tag)) { item.Status = "current"; continue; }
            // A pin stops the weekly run; naming the component explicitly (--component) is a deliberate upgrade.
            if (c.Pin && _o.Only == null) { item.Status = "pinned"; item.Notes.Add($"{release.Tag} available"); continue; }

            var (asset, assetError) = PickAsset(c, release);
            if (asset == null) { item.Status = "error"; item.Notes.Add(assetError!); continue; }
            item.Asset = asset;
            item.Status = "update";

            if (_o.NoDownload) continue;
            try { await ApplyAsync(item, releases.Http); }
            catch (Exception e)
            {
                item.Status = "error";
                item.Notes.Add(e.Message);
            }
        }

        if (!_o.DryRun) _lock.Save(_lockPath);
        if (_o.SummaryPath != null) File.WriteAllText(_o.SummaryPath, Summary(items));
        return items;
    }

    // ---------- versions and assets ----------

    public static string Normalize(string v)
    {
        v = v.Trim().ToLowerInvariant();
        foreach (string prefix in new[] { "release-v", "release-", "build-", "version", "v" })
            if (v.StartsWith(prefix) && v.Length > prefix.Length && char.IsDigit(v[prefix.Length]))
            {
                v = v[prefix.Length..];
                break;
            }
        return v.Trim();
    }

    public static bool SameVersion(string a, string b) => Normalize(a) == Normalize(b);

    private static readonly Regex ServerNative = new(@"/runtimes/linux(-musl)?-x64/", RegexOptions.IgnoreCase);

    private static readonly Regex NotForLinux = new(@"windows|win64|win32|-win\.|macos|osx|darwin|with-cssharp|\.pdb$|\.sha256$|\.md5$|\.sig$|\.asc$", RegexOptions.IgnoreCase);

    private (ReleaseAsset?, string?) PickAsset(Component c, Release r)
    {
        var assets = r.Assets;
        if (assets.Count == 0) return (null, "release has no files attached");
        List<ReleaseAsset> pick;
        if (!string.IsNullOrEmpty(c.Asset))
        {
            // "re:<regex>" for names a glob can't tell apart (e.g. "x-1.2.zip" vs "x-1.2-no-map-configs.zip").
            var glob = c.Asset.StartsWith("re:")
                ? new Regex(c.Asset[3..], RegexOptions.IgnoreCase)
                : new Regex("^" + Regex.Escape(c.Asset).Replace(@"\*", ".*").Replace(@"\?", ".") + "$", RegexOptions.IgnoreCase);
            pick = assets.Where(a => glob.IsMatch(a.Name)).ToList();
            if (pick.Count == 0) return (null, $"no file matches asset '{c.Asset}' (files: {string.Join(", ", assets.Select(a => a.Name))})");
        }
        else
        {
            pick = assets.Where(a => !NotForLinux.IsMatch(a.Name)).ToList();
            if (pick.Count > 1 && pick.Any(a => a.Name.Contains("linux", StringComparison.OrdinalIgnoreCase)))
                pick = pick.Where(a => a.Name.Contains("linux", StringComparison.OrdinalIgnoreCase)).ToList();
            if (pick.Count == 0) return (null, $"no Linux file in the release (files: {string.Join(", ", assets.Select(a => a.Name))})");
        }
        if (pick.Count > 1) return (null, $"several files match, set 'asset' in plugins.yaml: {string.Join(", ", pick.Select(a => a.Name))}");
        return (pick[0], null);
    }

    // ---------- download, map, write ----------

    private async Task ApplyAsync(PlanItem item, HttpClient http)
    {
        var c = item.Component;
        string safe = Regex.Replace(c.Name, @"[^A-Za-z0-9_.-]", "_");
        string downloads = Path.Combine(_o.WorkDir, "downloads", safe);
        Directory.CreateDirectory(downloads);
        string archive = _o.FromZip ?? Path.Combine(downloads, item.Asset!.Name);
        if (_o.FromZip == null && (!File.Exists(archive) || (item.Asset!.Size > 0 && new FileInfo(archive).Length != item.Asset.Size)))
        {
            using var res = await http.GetAsync(item.Asset.Url, HttpCompletionOption.ResponseHeadersRead);
            res.EnsureSuccessStatusCode();
            await using var fs = File.Create(archive);
            await res.Content.CopyToAsync(fs);
        }

        // Fresh, empty folder per run: archives are untrusted input.
        string root = Path.Combine(_o.WorkDir, "extract", safe);
        if (Directory.Exists(root)) Directory.Delete(root, true);
        Directory.CreateDirectory(root);
        Extract(archive, root);

        var map = new List<(string To, string From, bool AddOnly)>();
        var keptFiles = new List<string>();
        foreach (string p in c.Paths)
        {
            string? src = MapPath(root, p, c);
            if (src != null) { map.Add((p, src, false)); continue; }
            // A single file the release no longer ships (e.g. gamedata the plugin stopped needing): keep it, don't fail.
            if (!p.EndsWith('/') && File.Exists(_b.Full(p)))
            {
                keptFiles.Add(p);
                item.Notes.Add($"{p} is not in the release; kept as is");
                continue;
            }
            throw new InvalidOperationException($"can't find {p} in {item.Asset.Name}; add an 'install' entry in plugins.yaml");
        }
        foreach (string p in c.Configs)
        {
            string? src = MapPath(root, p, c);
            if (src != null) map.Add((p, src, true));
        }

        // Release files no mapping covers: a new gamedata file, a vdf in a new place. Reported so nothing is lost silently.
        var covered = map.Select(m => Path.GetFullPath(m.From)).ToList();
        var missed = Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
            .Where(f => !covered.Any(c => Path.GetFullPath(f).Equals(c, StringComparison.OrdinalIgnoreCase)
                                          || Path.GetFullPath(f).StartsWith(c + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)))
            .Select(f => Path.GetRelativePath(root, f).Replace('\\', '/'))
            .Where(f => !NotForLinux.IsMatch(f))
            .ToList();
        item.NotInstalled.AddRange(missed);

        var newFiles = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (string p in keptFiles) newFiles[p] = Lockfile.Hash(_b.Full(p));
        var keep = c.Keep.Select(Bundle.Glob).ToList();
        _lock.Components.TryGetValue(c.Name, out var old);

        foreach (var (to, from, addOnly) in map)
        {
            var files = Directory.Exists(from)
                ? Directory.EnumerateFiles(from, "*", SearchOption.AllDirectories).Select(f => (Src: f, Rel: to.TrimEnd('/') + "/" + Path.GetRelativePath(from, f).Replace('\\', '/')))
                : new[] { (Src: from, Rel: to.TrimEnd('/')) };
            foreach (var (src, rel) in files)
            {
                if (Blocked(c, to, rel, out string? why)) { item.Notes.Add($"skipped {rel}: {why}"); continue; }
                string target = _b.Full(rel);
                bool exists = File.Exists(target);
                if ((addOnly || keep.Any(k => k.IsMatch(rel))) && exists) continue;

                string hash = Lockfile.Hash(src);
                if (!addOnly) newFiles[rel] = hash;
                if (exists && Lockfile.Hash(target) == hash) { item.Unchanged++; continue; }
                if (exists) item.Changed++; else item.Added++;
                if (!_o.DryRun)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                    File.Copy(src, target, overwrite: true);
                }
            }
        }

        // Files the previous release installed that this one doesn't ship.
        if (old != null)
        {
            foreach (string rel in old.Files.Keys.Where(f => !newFiles.ContainsKey(f) && !keep.Any(k => k.IsMatch(f))))
            {
                if (!File.Exists(_b.Full(rel))) continue;
                if (old.Baseline && !_o.Prune) { item.PossiblyStale.Add(rel); continue; }
                // Releases sometimes drop runtimes/ while still using the managed wrapper (GG2 1.2.4 + SQLite):
                // never delete the native libraries for this server's platform on a guess.
                if (old.Baseline && ServerNative.IsMatch(rel)) { item.Notes.Add($"kept {rel}: native library for this server's platform"); continue; }
                item.Removed++;
                if (_o.DryRun) continue;
                File.Delete(_b.Full(rel));
                RemoveEmptyParents(Path.GetDirectoryName(_b.Full(rel))!);
            }
        }

        // A renamed plugin breaks `css_plugins unload "<old name>"` lines in mode cfgs.
        if (c.Kind == "plugin" && !string.IsNullOrEmpty(c.Module))
        {
            var pluginMap = map.FirstOrDefault(m => !m.AddOnly && m.To.Contains("/plugins/", StringComparison.OrdinalIgnoreCase) && Directory.Exists(m.From));
            string? currentDll = pluginMap.To != null ? _b.PluginDll(pluginMap.To) : null;
            string? newDll = currentDll != null ? Path.Combine(pluginMap.From, Path.GetFileName(currentDll)) : null;
            if (newDll != null && File.Exists(newDll) && AssemblyInspector.Read(newDll)?.ModuleName is string newModule && newModule != c.Module)
            {
                item.Notes.Add($"ModuleName changes '{c.Module}' -> '{newModule}': update css_plugins unload/reload lines in cfg/");
                if (!_o.DryRun) ManifestWriter.SetField(_manifestPath, c.Name, "module", newModule);
            }
        }

        if (_o.DryRun) return;
        _lock.Components[c.Name] = new LockEntry
        {
            Version = item.Latest!,
            Asset = item.Asset.Name,
            Url = item.Asset.Url,
            Installed = DateTime.UtcNow,
            Files = newFiles,
        };
        ManifestWriter.SetVersion(_manifestPath, c.Name, item.Latest!);
        if (c.Paths.Any(p => p.Equals("addons/counterstrikesharp/api/", StringComparison.OrdinalIgnoreCase)))
        {
            ManifestWriter.SetServerField(_manifestPath, "css_api", Normalize(item.Latest!));
            item.Notes.Add("server.css_api updated; every plugin is re-checked against it");
        }
        if (item.Repo != null && c.Source?.Github != null && !item.Repo.Equals(c.Source.Github, StringComparison.OrdinalIgnoreCase))
            item.Notes.Add("update 'source' in plugins.yaml to the new repository");
    }

    // Stop at the game dir; only folders left empty by the removal go.
    private void RemoveEmptyParents(string dir)
    {
        string stop = Path.GetFullPath(_b.GameDir).TrimEnd(Path.DirectorySeparatorChar);
        for (var d = new DirectoryInfo(dir); d != null && d.Exists && d.FullName.TrimEnd(Path.DirectorySeparatorChar) != stop; d = d.Parent)
        {
            if (d.EnumerateFileSystemInfos().Any()) break;
            d.Delete();
        }
    }

    private static void Extract(string archive, string dest)
    {
        string name = archive.ToLowerInvariant();
        if (name.EndsWith(".zip")) ZipFile.ExtractToDirectory(archive, dest, overwriteFiles: true);
        else if (name.EndsWith(".tar.gz") || name.EndsWith(".tgz"))
        {
            using var fs = File.OpenRead(archive);
            using var gz = new GZipStream(fs, CompressionMode.Decompress);
            TarFile.ExtractToDirectory(gz, dest, overwriteFiles: true);
        }
        else if (name.EndsWith(".dll"))
            File.Copy(archive, Path.Combine(dest, Path.GetFileName(archive)));
        else throw new InvalidOperationException($"don't know how to unpack {Path.GetFileName(archive)}");
    }

    // Contract copies and CSS's own API must not be dropped into a plugin folder (see the placement check).
    private bool Blocked(Component c, string to, string rel, out string? why)
    {
        why = null;
        if (!rel.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) || !to.Contains("/plugins/", StringComparison.OrdinalIgnoreCase)) return false;
        string name = Path.GetFileNameWithoutExtension(rel);
        if (name.Equals("CounterStrikeSharp.API", StringComparison.OrdinalIgnoreCase) && c.Kind != "core")
        {
            why = "the server provides CounterStrikeSharp.API";
            return true;
        }
        bool ownShared = c.Paths.Any(p => p.Contains("/shared/" + name + "/", StringComparison.OrdinalIgnoreCase));
        if (_sharedNames.Contains(name) || ownShared)
        {
            why = $"{name} belongs in shared/";
            return true;
        }
        return false;
    }

    // Where a component path comes from inside the extracted archive:
    //   1. an 'install' override,
    //   2. the longest matching tail of the path ("plugins/disabled/X" is matched as "plugins/X"),
    //   3. for plugin / shared folders, the folder that holds the main DLL.
    private string? MapPath(string root, string to, Component c)
    {
        var over = c.Install.FirstOrDefault(i => i.To.TrimEnd('/').Equals(to.TrimEnd('/'), StringComparison.OrdinalIgnoreCase));
        if (over != null)
        {
            string from = over.From.TrimEnd('/');
            if (from.StartsWith("*/"))
            {
                foreach (string top in Directory.GetDirectories(root))
                {
                    string candidate = Path.Combine(top, from[2..]);
                    if (Directory.Exists(candidate) || File.Exists(candidate)) return candidate;
                }
                return null;
            }
            string full = Path.Combine(root, from);
            return Directory.Exists(full) || File.Exists(full) ? full : null;
        }

        bool isDir = to.EndsWith('/');
        var segs = to.TrimEnd('/').Split('/').Where(s => !s.Equals("disabled", StringComparison.OrdinalIgnoreCase)).ToArray();
        var entries = (isDir ? Directory.EnumerateDirectories(root, "*", SearchOption.AllDirectories) : Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
            .Select(e => (Full: e, Segs: Path.GetRelativePath(root, e).Replace('\\', '/').Split('/')))
            .ToList();

        // Match at least from the folder that says what the path is: "configs/plugins/X" or "cfg/X" for configs (so a
        // config never lands on the plugin folder "plugins/X"), "plugins/X" / "shared/X" for code, else two segments.
        int minK = Math.Min(2, segs.Length);
        foreach (string anchor in new[] { "configs", "cfg", "plugins", "shared" })
        {
            int idx = Array.FindIndex(segs, s => s.Equals(anchor, StringComparison.OrdinalIgnoreCase));
            if (idx >= 0) { minK = segs.Length - idx; break; }
        }

        for (int k = segs.Length; k >= minK; k--)
        {
            var tail = segs[^k..];
            var matches = entries.Where(e => e.Segs.Length >= k && e.Segs[^k..].SequenceEqual(tail, StringComparer.OrdinalIgnoreCase)).ToList();
            if (matches.Count == 0) continue;
            int shortest = matches.Min(m => m.Segs.Length);
            var best = matches.Where(m => m.Segs.Length == shortest).ToList();
            if (best.Count == 1) return best[0].Full;
        }

        if (isDir && (to.Contains("/plugins/") || to.Contains("/shared/")) && !to.Contains("/configs/"))
        {
            string current = _b.PluginDll(to) is string dll ? Path.GetFileName(dll) : segs[^1] + ".dll";
            var hits = Directory.EnumerateFiles(root, current, SearchOption.AllDirectories).ToList();
            if (hits.Count == 1) return Path.GetDirectoryName(hits[0]);
        }
        return null;
    }

    // ---------- report ----------

    public static string Summary(List<PlanItem> items)
    {
        var sb = new StringBuilder();
        var updates = items.Where(i => i.Status == "update").ToList();
        sb.AppendLine($"## Plugin updates ({updates.Count})");
        sb.AppendLine();
        sb.AppendLine("| Component | Installed | Latest | File | Changes | Notes |");
        sb.AppendLine("| --- | --- | --- | --- | --- | --- |");
        foreach (var i in items.Where(i => i.Status is "update" or "error" or "pinned").OrderBy(i => i.Status).ThenBy(i => i.Component.Name))
        {
            string link = i.Component.Source?.Github != null && i.Latest != null
                ? $"[{i.Latest}](https://github.com/{i.Repo ?? i.Component.Source.Github}/releases/tag/{i.Latest})"
                : i.Latest ?? "";
            string changes = i.Status == "update" ? $"+{i.Added} ~{i.Changed} -{i.Removed}" : i.Status;
            var notes = i.Notes.ToList();
            if (i.NotInstalled.Count > 0) notes.Add($"not installed from the release: {string.Join(", ", i.NotInstalled.Take(5))}{(i.NotInstalled.Count > 5 ? " …" : "")}");
            if (i.PossiblyStale.Count > 0) notes.Add($"{i.PossiblyStale.Count} old file(s) not in the new release, left in place: {string.Join(", ", i.PossiblyStale.Take(5))}{(i.PossiblyStale.Count > 5 ? " …" : "")}");
            sb.AppendLine($"| {i.Component.Name} | {i.Component.Version} | {link} | {i.Asset?.Name} | {changes} | {string.Join("; ", notes).Replace("|", "\\|")} |");
        }
        sb.AppendLine();
        sb.AppendLine($"Up to date: {string.Join(", ", items.Where(i => i.Status == "current").Select(i => i.Component.Name))}");
        var skipped = items.Where(i => i.Status == "skipped").Select(i => i.Component.Name).ToList();
        if (skipped.Count > 0) sb.AppendLine($"\nNo source (not checked): {string.Join(", ", skipped)}");
        return sb.ToString();
    }
}
