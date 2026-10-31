using System.Text.Json;
using System.Text.RegularExpressions;
using Gameloop.Vdf;

namespace ServerBundleCheck;

public static class Checks
{
    // Contract assemblies that break other plugins when a copy sits next to a plugin DLL instead of only in shared/.
    private static readonly string[] StrictContracts = { "MenuManagerApi", "CounterStrikeSharp.API" };

    public static void Run(Bundle b)
    {
        ManifestShape(b);
        Coverage(b);
        var runtime = Runtime(b);
        Assemblies(b, runtime);
        Placement(b);
        Cfgs(b);
        Configs(b);
        Secrets(b);
    }

    // ---------- plugins.yaml itself ----------

    private static void ManifestShape(Bundle b)
    {
        const string check = "manifest";
        var kinds = new[] { "core", "metamod", "plugin", "shared", "content" };
        foreach (var dup in b.Manifest.Components.GroupBy(c => c.Name, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1))
            b.Report.Error(check, $"Component '{dup.Key}' is listed {dup.Count()} times");

        foreach (var c in b.Manifest.Components)
        {
            if (!kinds.Contains(c.Kind)) b.Report.Error(check, $"{c.Name}: kind '{c.Kind}' must be one of {string.Join(", ", kinds)}");
            if (c.Paths.Count == 0) b.Report.Error(check, $"{c.Name}: no paths");
            if (c.Kind != "content" && (c.Source == null || (c.Source.Github == null && c.Source.Url == null)))
                b.Report.Warn(check, $"{c.Name}: no source, so it can't be updated automatically");
            if (c.Kind == "plugin" && string.IsNullOrEmpty(c.Module))
                b.Report.Warn(check, $"{c.Name}: no module name (needed to check css_plugins unload lines)");

            foreach (string p in c.Paths.Concat(c.Configs))
            {
                if (p.Contains('*')) continue;
                string full = b.Full(p);
                bool exists = p.EndsWith('/') ? Directory.Exists(full) : File.Exists(full) || Directory.Exists(full);
                if (!exists)
                {
                    if (c.Configs.Contains(p)) b.Report.Info(check, $"{c.Name}: config {p} not in repo (created on first start)");
                    else b.Report.Error(check, $"{c.Name}: path {p} does not exist");
                }
            }
            foreach (string r in c.Requires)
                if (!b.Manifest.Components.Any(o => o.Name.Equals(r, StringComparison.OrdinalIgnoreCase)))
                    b.Report.Error(check, $"{c.Name}: requires '{r}', which is not in plugins.yaml");
        }
    }

    // ---------- every installed thing is in plugins.yaml ----------

    private static void Coverage(Bundle b)
    {
        const string check = "coverage";
        string addons = Path.Combine(b.GameDir, "addons");
        var items = new List<(string Rel, bool Config)>();
        if (Directory.Exists(addons))
        {
            foreach (string d in Directory.GetDirectories(addons))
                if (Path.GetFileName(d) != "counterstrikesharp") items.Add((b.Rel(d) + "/", false));
            foreach (string f in Directory.GetFiles(addons, "*.vdf")) items.Add((b.Rel(f), false));
            string mm = Path.Combine(addons, "metamod");
            if (Directory.Exists(mm))
                foreach (string f in Directory.GetFiles(mm, "*.vdf")) items.Add((b.Rel(f), false));
        }
        items.AddRange(b.PluginFolders().Select(p => (p, false)));
        items.AddRange(b.SharedFolders().Select(p => (p, false)));
        string cfgs = Path.Combine(b.CssDir, "configs", "plugins");
        if (Directory.Exists(cfgs))
            items.AddRange(Directory.GetDirectories(cfgs).Select(d => (b.Rel(d) + "/", true)));

        foreach (var (rel, config) in items)
        {
            if (b.IsIgnored(rel) || b.Owner(rel) != null) continue;
            if (config) b.Report.Warn(check, $"{rel} belongs to no component (left over from a removed plugin?)", b.RepoRel(b.Full(rel)));
            else b.Report.Error(check, $"{rel} is installed but not in plugins.yaml", b.RepoRel(b.Full(rel)));
        }
    }

    // ---------- CounterStrikeSharp + .NET runtime in the repo ----------

    public sealed record RuntimeInfo(int? CssBuild, int? DotnetMajor);

    private static RuntimeInfo Runtime(Bundle b)
    {
        const string check = "runtime";
        int? build = null;
        var api = b.Assembly(Path.Combine(b.CssDir, "api", "CounterStrikeSharp.API.dll"));
        if (api == null) b.Report.Error(check, "addons/counterstrikesharp/api/CounterStrikeSharp.API.dll missing");
        else
        {
            // CSS stamps the build into the assembly version: 1.0.<build>.0
            build = api.Version.Build;
            string want = b.Manifest.Server.CssApi;
            string have = $"{api.Version.Major}.{api.Version.Minor}.{api.Version.Build}";
            if (!string.IsNullOrEmpty(want) && want.TrimStart('v') != have)
                b.Report.Error(check, $"plugins.yaml says css_api {want}, the repo has CounterStrikeSharp.API {have}");
            b.Report.Info(check, $"CounterStrikeSharp.API {have}, {api.TargetFramework}");
        }

        int? dotnet = null;
        string fx = Path.Combine(b.CssDir, "dotnet", "shared", "Microsoft.NETCore.App");
        if (Directory.Exists(fx))
        {
            var versions = Directory.GetDirectories(fx).Select(Path.GetFileName)
                .Select(v => Version.TryParse(v, out var ver) ? ver : null).Where(v => v != null).Cast<Version>().OrderBy(v => v).ToList();
            if (versions.Count > 0) dotnet = versions[^1].Major;
            if (versions.Count > 1)
                b.Report.Warn(check, $"Several .NET runtimes bundled ({string.Join(", ", versions)}); CSS uses one, the others are dead weight",
                    b.RepoRel(fx));
            if (api?.TargetMajor is int apiMajor && dotnet is int rt && apiMajor > rt)
                b.Report.Error(check, $"CounterStrikeSharp.API targets .NET {apiMajor} but the bundled runtime is .NET {rt}");
        }
        else if (b.Manifest.Server.Platform == "linux")
            b.Report.Warn(check, "No bundled .NET runtime (addons/counterstrikesharp/dotnet); use the CSS with-runtime build");

        return new RuntimeInfo(build, dotnet);
    }

    // ---------- each plugin DLL against the runtime ----------

    private static void Assemblies(Bundle b, RuntimeInfo rt)
    {
        const string check = "compatibility";
        var available = AvailableAssemblies(b);

        foreach (string folder in b.PluginFolders())
        {
            if (b.IsIgnored(folder)) continue;
            string? dll = b.PluginDll(folder);
            if (dll == null) { b.Report.Error(check, $"{folder}: no plugin DLL", b.RepoRel(b.Full(folder))); continue; }
            var info = b.Assembly(dll);
            if (info == null) continue;
            string where = b.RepoRel(dll);
            var owner = b.Owner(folder);
            string label = owner?.Name ?? folder;

            if (!info.IsPlugin) b.Report.Error(check, $"{label}: {Path.GetFileName(dll)} has no BasePlugin class", where);

            if (info.TargetMajor is int tfm && rt.DotnetMajor is int net && tfm > net)
                b.Report.Error(check, $"{label}: built for .NET {tfm}, server runtime is .NET {net}", where);

            if (info.MinimumApiVersion is int min && rt.CssBuild is int css && min > css)
                b.Report.Error(check, $"{label}: needs CounterStrikeSharp API {min}+, server has {css}", where);

            var cssRef = info.References.FirstOrDefault(r => r.Name == "CounterStrikeSharp.API");
            if (cssRef.Name != null && rt.CssBuild is int build && cssRef.Version.Build > build)
                b.Report.Error(check, $"{label}: compiled against CounterStrikeSharp.API 1.0.{cssRef.Version.Build}, server has 1.0.{build}", where);

            if (owner != null && !string.IsNullOrEmpty(owner.Module) && info.ModuleName != null && owner.Module != info.ModuleName)
                b.Report.Error(check, $"{label}: plugins.yaml module '{owner.Module}' but the DLL says '{info.ModuleName}'", where);

            // References: framework, CSS api folder, shared/*, or the plugin's own folder.
            var local = Directory.GetFiles(Path.GetDirectoryName(dll)!, "*.dll", SearchOption.AllDirectories)
                .Select(Path.GetFileNameWithoutExtension).ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var (refName, _) in info.References)
            {
                if (available.Contains(refName) || local.Contains(refName!)) continue;
                b.Report.Warn(check, $"{label}: references {refName}, which is not in the plugin folder, shared/ or the runtime", where);
            }
        }

        foreach (string folder in b.SharedFolders())
        {
            string name = Path.GetFileName(folder.TrimEnd('/'));
            string main = Path.Combine(b.Full(folder), name + ".dll");
            if (!File.Exists(main))
            {
                b.Report.Error(check, $"{folder}: no {name}.dll, so CSS loads nothing from this folder", b.RepoRel(b.Full(folder)));
                continue;
            }
            var info = b.Assembly(main);
            if (info?.TargetMajor is int tfm && rt.DotnetMajor is int net && tfm > net)
                b.Report.Error(check, $"{folder}: {name}.dll built for .NET {tfm}, server runtime is .NET {net}", b.RepoRel(main));
        }
    }

    private static HashSet<string> AvailableAssemblies(Bundle b)
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void AddDir(string dir, SearchOption opt)
        {
            if (!Directory.Exists(dir)) return;
            foreach (string f in Directory.GetFiles(dir, "*.dll", opt)) set.Add(Path.GetFileNameWithoutExtension(f));
        }
        AddDir(Path.Combine(b.CssDir, "api"), SearchOption.TopDirectoryOnly);
        AddDir(Path.Combine(b.CssDir, "dotnet", "shared"), SearchOption.AllDirectories);
        foreach (string name in b.SharedAssemblyNames()) set.Add(name);
        return set;
    }

    // ---------- files in the wrong place ----------

    private static void Placement(Bundle b)
    {
        const string check = "placement";
        var shared = b.SharedAssemblyNames().ToHashSet(StringComparer.OrdinalIgnoreCase);

        foreach (string folder in b.PluginFolders())
        {
            if (b.IsIgnored(folder)) continue;
            string full = b.Full(folder);
            string label = b.Owner(folder)?.Name ?? folder;
            string? pluginDll = b.PluginDll(folder);
            foreach (string dll in Directory.GetFiles(full, "*.dll"))
            {
                if (dll == pluginDll) continue;
                string name = Path.GetFileNameWithoutExtension(dll);
                // Exact case: PMM's contract is MenuManagerApi; our old plugin is MenuManagerAPI.
                if (StrictContracts.Contains(name, StringComparer.Ordinal))
                    b.Report.Warn(check, $"{label}: ships its own {name}.dll; the server's copy must be the only one", b.RepoRel(dll));
                else if (shared.Contains(name))
                    b.Report.Warn(check, $"{label}: {name}.dll is also in shared/; the plugin folder copy can load a second, different version", b.RepoRel(dll));
                if (name.Equals("0Harmony", StringComparison.OrdinalIgnoreCase))
                    b.Report.Error(check, $"{label}: 0Harmony.dll next to the plugin DLL; it must be in harmony/", b.RepoRel(dll));
            }
        }
    }

    // ---------- cfg files: plugin loads/unloads and Metamod loads ----------

    private static readonly Regex PluginCmd = new(@"^\s*css_plugins\s+(load|unload|reload)\s+""?([^""]+?)""?\s*$", RegexOptions.IgnoreCase);
    private static readonly Regex MetaLoad = new(@"^\s*meta\s+load\s+""?([^""\s]+)""?", RegexOptions.IgnoreCase);

    private static void Cfgs(Bundle b)
    {
        const string check = "cfg";
        string cfgDir = Path.Combine(b.GameDir, "cfg");
        if (!Directory.Exists(cfgDir)) return;

        // Module names actually installed (read from the DLLs), plus the manifest's.
        var modules = new Dictionary<string, Component?>(StringComparer.Ordinal);
        foreach (string folder in b.PluginFolders())
        {
            string? dll = b.PluginDll(folder);
            string? m = dll != null ? b.Assembly(dll)?.ModuleName : null;
            if (m != null) modules[m] = b.Owner(folder);
        }
        foreach (var c in b.Manifest.Components.Where(c => !string.IsNullOrEmpty(c.Module)))
            modules.TryAdd(c.Module!, c);
        var alwaysLoaded = b.Manifest.Components.Where(c => c.AlwaysLoaded && c.Module != null).Select(c => c.Module!).ToHashSet();

        foreach (string file in Directory.GetFiles(cfgDir, "*.cfg", SearchOption.AllDirectories))
        {
            string rel = b.Rel(file);
            if (b.IsIgnored(rel)) continue;
            string? text = b.ReadText(file, check);
            if (text == null) continue;
            string where = b.RepoRel(file);
            foreach (string raw in text.Split('\n'))
            {
                string line = StripComment(raw);
                if (line.Length == 0) continue;

                var pm = PluginCmd.Match(line);
                if (pm.Success)
                {
                    string verb = pm.Groups[1].Value.ToLowerInvariant(), target = pm.Groups[2].Value.Trim();
                    if (verb == "load" || target.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
                    {
                        if (!File.Exists(Path.Combine(b.CssDir, target.Replace('/', Path.DirectorySeparatorChar))))
                            b.Report.Error(check, $"css_plugins {verb} \"{target}\": file not found under addons/counterstrikesharp/", where);
                        continue;
                    }
                    if (!modules.ContainsKey(target))
                        b.Report.Warn(check, $"css_plugins {verb} \"{target}\": no installed plugin has that ModuleName", where);
                    if (verb == "unload" && alwaysLoaded.Contains(target))
                        b.Report.Error(check, $"css_plugins unload \"{target}\": this plugin is always_loaded in plugins.yaml", where);
                    continue;
                }

                var mm = MetaLoad.Match(line);
                if (mm.Success)
                {
                    string target = mm.Groups[1].Value;
                    bool linux = b.Manifest.Server.Platform == "linux";
                    string ext = linux ? ".so" : ".dll";
                    string path = Path.Combine(b.GameDir, target.Replace('/', Path.DirectorySeparatorChar));
                    if (!File.Exists(path) && !File.Exists(path + ext))
                        b.Report.Error(check, $"meta load {target}: {Path.GetFileName(target)}{ext} not found", where);
                }
            }
        }
    }

    private static string StripComment(string line)
    {
        bool quoted = false;
        for (int i = 0; i < line.Length - 1; i++)
        {
            if (line[i] == '"') quoted = !quoted;
            if (!quoted && line[i] == '/' && line[i + 1] == '/') return line[..i].Trim();
        }
        return line.Trim();
    }

    // ---------- configs parse ----------

    private static void Configs(Bundle b)
    {
        const string check = "configs";
        var options = new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };
        string cfgRoot = Path.Combine(b.CssDir, "configs");
        if (Directory.Exists(cfgRoot))
        {
            foreach (string file in Directory.GetFiles(cfgRoot, "*.json", SearchOption.AllDirectories))
            {
                if (b.IsIgnored(b.Rel(file))) continue;
                string? text = b.ReadText(file, check);
                if (text == null) continue;
                try { using var _ = JsonDocument.Parse(text, options); }
                catch (JsonException e) { b.Report.Error(check, $"{b.Rel(file)} is not valid JSON: {e.Message}", b.RepoRel(file)); }
            }
        }

        var mapGroups = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string gamemodes = Path.Combine(b.GameDir, "gamemodes_server.txt");
        if (File.Exists(gamemodes))
        {
            string? text = b.ReadText(gamemodes, check);
            if (text != null)
            {
                try
                {
                    var root = VdfConvert.Deserialize(text);
                    if (root.Value is Gameloop.Vdf.Linq.VObject obj && obj["mapgroups"] is Gameloop.Vdf.Linq.VObject groups)
                        foreach (var g in groups.Children().OfType<Gameloop.Vdf.Linq.VProperty>()) mapGroups.Add(g.Key);
                }
                catch (Exception e) { b.Report.Error(check, $"gamemodes_server.txt does not parse as VDF: {e.Message}", b.RepoRel(gamemodes)); }
            }
        }

        GameModeManagerModes(b, check, options, mapGroups);
    }

    // GameModeManager.json: every mode's cfg exists and its map groups are in gamemodes_server.txt.
    private static void GameModeManagerModes(Bundle b, string check, JsonDocumentOptions options, HashSet<string> mapGroups)
    {
        string file = Path.Combine(b.CssDir, "configs", "plugins", "GameModeManager", "GameModeManager.json");
        if (!File.Exists(file)) return;
        string? text = b.ReadText(file, check);
        if (text == null) return;
        JsonDocument doc;
        try { doc = JsonDocument.Parse(text, options); }
        catch (JsonException) { return; } // reported above
        using (doc)
        {
            if (!doc.RootElement.TryGetProperty("GameModes", out var gm) || !gm.TryGetProperty("List", out var list)) return;
            foreach (var mode in list.EnumerateArray())
            {
                string name = mode.TryGetProperty("Name", out var n) ? n.GetString() ?? "?" : "?";
                if (mode.TryGetProperty("Config", out var cfg) && cfg.GetString() is string c &&
                    !File.Exists(Path.Combine(b.GameDir, "cfg", c.Replace('/', Path.DirectorySeparatorChar))))
                    b.Report.Error(check, $"GameModeManager mode '{name}': cfg/{c} not found", b.RepoRel(file));
                if (mapGroups.Count > 0 && mode.TryGetProperty("MapGroups", out var groups))
                    foreach (var g in groups.EnumerateArray())
                        if (g.GetString() is string group && !mapGroups.Contains(group))
                            b.Report.Error(check, $"GameModeManager mode '{name}': map group {group} not in gamemodes_server.txt", b.RepoRel(file));
            }
        }
    }

    // ---------- secrets in tracked files ----------

    private static readonly (Regex Pattern, string What, bool Error)[] SecretPatterns =
    {
        (new(@"https://(ptb\.|canary\.)?discord(app)?\.com/api/webhooks/\d+/[\w-]{20,}", RegexOptions.IgnoreCase), "Discord webhook URL", true),
        (new(@"\bsv_setsteamaccount\s+""?[0-9A-F]{32}", RegexOptions.IgnoreCase), "Steam game server login token", true),
        (new(@"(api[_-]?key|steam_?key|apikey)""?\s*[:=]\s*""?[0-9A-F]{32}\b", RegexOptions.IgnoreCase), "Steam Web API key", true),
        (new(@"""(password|dbpassword|databasepassword|mysqlpassword)""\s*:\s*""[^""]{3,}""", RegexOptions.IgnoreCase), "password in config", false),
    };

    private static void Secrets(Bundle b)
    {
        const string check = "secrets";
        var exts = new[] { ".json", ".cfg", ".txt", ".ini", ".env", ".yaml", ".yml", ".toml" };
        var files = new List<string>();
        if (Directory.Exists(b.GameDir))
            files.AddRange(Directory.EnumerateFiles(b.GameDir, "*", SearchOption.AllDirectories)
                .Where(f => exts.Contains(Path.GetExtension(f), StringComparer.OrdinalIgnoreCase)));
        string env = Path.Combine(b.Repo, ".env");
        if (File.Exists(env)) files.Add(env);

        foreach (string file in files)
        {
            if (file.StartsWith(b.GameDir) && b.IsIgnored(b.Rel(file))) continue;
            if (new FileInfo(file).Length > 2_000_000) continue;
            string? text;
            try { text = File.ReadAllText(file); }
            catch { continue; } // unreadable files are reported by the checks that need them
            foreach (var (pattern, what, error) in SecretPatterns)
            {
                var m = pattern.Match(text);
                if (!m.Success) continue;
                int line = text[..m.Index].Count(ch => ch == '\n') + 1;
                string msg = $"{what} at line {line} (value not shown); move it to the server-only custom_files or a secret";
                if (error) b.Report.Error(check, msg, b.RepoRel(file));
                else b.Report.Warn(check, msg, b.RepoRel(file));
            }
        }
    }
}
