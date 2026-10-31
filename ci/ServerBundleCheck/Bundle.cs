using System.Text.RegularExpressions;

namespace ServerBundleCheck;

// The repo as the checks see it: paths, the manifest, and assemblies read on demand.
public sealed class Bundle
{
    public string Repo { get; }
    public Manifest Manifest { get; }
    public Report Report { get; }
    public string GameDir { get; }
    public string CssDir { get; }

    private readonly Dictionary<string, AssemblyInfo?> _assemblies = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<Regex> _ignore;

    public Bundle(string repo, Manifest manifest, Report report)
    {
        Repo = repo;
        Manifest = manifest;
        Report = report;
        GameDir = Path.Combine(repo, manifest.Server.GameDir);
        CssDir = Path.Combine(GameDir, "addons", "counterstrikesharp");
        _ignore = manifest.Ignore.Select(Glob).ToList();
    }

    // Path relative to the game dir with "/" separators, as written in plugins.yaml and cfg files.
    public string Rel(string fullPath) => Path.GetRelativePath(GameDir, fullPath).Replace('\\', '/');

    // Path relative to the repo, for annotations.
    public string RepoRel(string fullPath) => Path.GetRelativePath(Repo, fullPath).Replace('\\', '/');

    public string Full(string gameRel) => Path.Combine(GameDir, gameRel.TrimEnd('/').Replace('/', Path.DirectorySeparatorChar));

    public bool IsIgnored(string gameRel) => _ignore.Any(r => r.IsMatch(gameRel) || r.IsMatch(gameRel.TrimEnd('/') + "/"));

    // The component that owns a path: the most specific Paths/Configs entry equal to it or a folder entry containing it.
    public Component? Owner(string gameRel)
    {
        string p = gameRel.TrimEnd('/');
        Component? best = null;
        int bestLength = -1;
        foreach (var c in Manifest.Components)
            foreach (string owned in c.Paths.Concat(c.Configs))
            {
                string o = owned.TrimEnd('/');
                bool match = p.Equals(o, StringComparison.OrdinalIgnoreCase)
                    || (owned.EndsWith('/') && p.StartsWith(o + "/", StringComparison.OrdinalIgnoreCase))
                    || (owned.Contains('*') && Glob(owned).IsMatch(p));
                if (match && o.Length > bestLength)
                {
                    best = c;
                    bestLength = o.Length;
                }
            }
        return best;
    }

    public AssemblyInfo? Assembly(string fullPath)
    {
        if (_assemblies.TryGetValue(fullPath, out var cached)) return cached;
        AssemblyInfo? info = null;
        try { info = AssemblyInspector.Read(fullPath); }
        catch (Exception e) { Report.Error("files", $"Cannot read {Rel(fullPath)}: {e.Message}{OneDriveHint(e)}", RepoRel(fullPath)); }
        _assemblies[fullPath] = info;
        return info;
    }

    public string? ReadText(string fullPath, string check)
    {
        try { return File.ReadAllText(fullPath); }
        catch (Exception e)
        {
            Report.Error(check, $"Cannot read {Rel(fullPath)}: {e.Message}{OneDriveHint(e)}", RepoRel(fullPath));
            return null;
        }
    }

    // Plugin folders under plugins/ and plugins/disabled/ (game-relative, ending in "/").
    public IEnumerable<string> PluginFolders()
    {
        string plugins = Path.Combine(CssDir, "plugins");
        if (!Directory.Exists(plugins)) yield break;
        foreach (string d in Directory.GetDirectories(plugins))
        {
            if (Path.GetFileName(d) == "disabled")
            {
                foreach (string dd in Directory.GetDirectories(d)) yield return Rel(dd) + "/";
                continue;
            }
            yield return Rel(d) + "/";
        }
    }

    public IEnumerable<string> SharedFolders()
    {
        string shared = Path.Combine(CssDir, "shared");
        return Directory.Exists(shared) ? Directory.GetDirectories(shared).Select(d => Rel(d) + "/") : Enumerable.Empty<string>();
    }

    // Assemblies CSS shares with every plugin: only shared/<Name>/<Name>.dll (PluginManager.LoadSharedLibraries).
    // Other DLLs in a shared folder are that library's private dependencies.
    public IEnumerable<string> SharedAssemblyNames() => SharedFolders()
        .Select(f => Path.GetFileName(f.TrimEnd('/')))
        .Where(n => File.Exists(Path.Combine(CssDir, "shared", n, n + ".dll")));

    // The plugin DLL of a folder: <folder>/<FolderName>.dll, else the only DLL with a BasePlugin class.
    public string? PluginDll(string folderRel)
    {
        string full = Full(folderRel);
        if (!Directory.Exists(full)) return null;     // not installed yet (first install by the updater)
        string main = Path.Combine(full, Path.GetFileName(full) + ".dll");
        if (File.Exists(main) && Assembly(main)?.IsPlugin == true) return main;
        foreach (string dll in Directory.GetFiles(full, "*.dll"))
            if (Assembly(dll)?.IsPlugin == true) return dll;
        return File.Exists(main) ? main : null;
    }

    // "addons/**", "cfg/*.cfg" -> regex over game-relative paths.
    public static Regex Glob(string glob)
    {
        string re = Regex.Escape(glob.TrimEnd('/'))
            .Replace(@"\*\*/", "(.*/)?")
            .Replace(@"\*\*", ".*")
            .Replace(@"\*", "[^/]*")
            .Replace(@"\?", "[^/]");
        return new Regex("^" + re + "(/.*)?$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }

    private static string OneDriveHint(Exception e) =>
        e is IOException or UnauthorizedAccessException
            ? " (if this folder is in OneDrive, the file may be online-only: mark the folder 'Always keep on this device')"
            : "";
}
