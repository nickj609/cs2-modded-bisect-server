using YamlDotNet.Serialization;
using YamlDotNet.Serialization.NamingConventions;

namespace ServerBundleCheck;

// plugins.yaml at the repo root: everything installed on the server and where its files live.
public sealed class Manifest
{
    public int Schema { get; set; } = 1;
    public ServerInfo Server { get; set; } = new();

    // Paths under GameDir the checker leaves alone (globs, "/" separators).
    public List<string> Ignore { get; set; } = new();
    public List<Component> Components { get; set; } = new();

    public static Manifest Load(string path)
    {
        var yaml = File.ReadAllText(path);
        var deserializer = new DeserializerBuilder()
            .WithNamingConvention(UnderscoredNamingConvention.Instance)
            .Build();
        var manifest = deserializer.Deserialize<Manifest>(yaml) ?? new Manifest();

        // A key written with no items ("ignore:") deserializes to null.
        manifest.Server ??= new ServerInfo();
        manifest.Ignore ??= new();
        manifest.Components ??= new();
        manifest.Components.RemoveAll(c => c == null);
        foreach (var c in manifest.Components)
        {
            c.Paths ??= new();
            c.Configs ??= new();
            c.Requires ??= new();
            c.Install ??= new();
            c.Keep ??= new();
        }
        return manifest;
    }
}

public sealed class ServerInfo
{
    // linux or windows: which native binaries must exist.
    public string Platform { get; set; } = "linux";

    // CounterStrikeSharp build the server runs (e.g. 1.0.362). Checked against the API dll in the repo.
    public string CssApi { get; set; } = "";

    // Folder that is uploaded as game/csgo.
    public string GameDir { get; set; } = "game/csgo";
}

public sealed class Component
{
    public string Name { get; set; } = "";

    // core (Metamod, CSS), metamod (Metamod plugin), plugin (CSS plugin), shared (CSS shared library), content.
    public string Kind { get; set; } = "plugin";

    public Source? Source { get; set; }

    // Release asset glob the updater downloads.
    public string? Asset { get; set; }
    public string Version { get; set; } = "";

    // true: the updater never changes this component.
    public bool Pin { get; set; }

    // CSS plugins: ModuleName as shown by css_plugins list (used by css_plugins unload lines).
    public string? Module { get; set; }

    // Plugin is loaded on every mode; it must never be unloaded by a cfg.
    public bool AlwaysLoaded { get; set; }

    // Files and folders this component owns (relative to GameDir). Folders end with "/".
    public List<string> Paths { get; set; } = new();

    // Config files/folders the component creates; the updater adds them only if missing.
    public List<string> Configs { get; set; } = new();

    // Other components (by name) this one needs.
    public List<string> Requires { get; set; } = new();

    // Updater: where an owned path comes from inside the release archive, when matching by folder name can't tell.
    public List<InstallMap> Install { get; set; } = new();

    // Updater: files under the owned paths that are never overwritten or removed (data the plugin writes, local edits).
    public List<string> Keep { get; set; } = new();

    public string? Notes { get; set; }
}

public sealed class InstallMap
{
    // Folder or file inside the extracted archive ("/" separators). May start with "*/" to skip a top folder.
    public string From { get; set; } = "";

    // An entry of the component's paths (game-relative).
    public string To { get; set; } = "";
}

public sealed class Source
{
    public string? Github { get; set; }
    public string? Url { get; set; }

    // url sources: regex over the page; the match is the download link, group "version" the version.
    public string? Pattern { get; set; }
}
