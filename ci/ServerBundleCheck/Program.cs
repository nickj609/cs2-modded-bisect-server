using ServerBundleCheck;

// Usage:
//   ServerBundleCheck check     [--repo <path>] [--manifest plugins.yaml] [--strict] [--verbose] [--markdown <file.md>]
//   ServerBundleCheck inventory [--repo <path>]
//   ServerBundleCheck lock --init [--force] [--component <name>]
//   ServerBundleCheck update    [--dry-run] [--no-download] [--prune] [--component <name>] [--work-dir <dir>] [--summary <file.md>] [--verbose]
//   ServerBundleCheck update    --component <name> --from-zip <file.zip> --version <version> [--prune] [--dry-run]    (a local build instead of the latest release)
// Exit code: 0 = no errors, 1 = errors (or warnings with --strict; update: a component failed), 2 = bad arguments.

string command = args.Length > 0 && !args[0].StartsWith("--") ? args[0] : "check";
string repo = Arg("--repo") ?? FindRepoRoot(Directory.GetCurrentDirectory());
string manifestPath = Path.Combine(repo, Arg("--manifest") ?? "plugins.yaml");
bool strict = args.Contains("--strict");
bool verbose = args.Contains("--verbose");
bool github = Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true";

if (command == "inventory")
{
    Inventory.Print(repo, File.Exists(manifestPath) ? Manifest.Load(manifestPath).Server.GameDir : "game/csgo");
    return 0;
}

if (command is not ("check" or "lock" or "update"))
{
    Console.Error.WriteLine($"Unknown command '{command}'. Use 'check', 'inventory', 'lock --init' or 'update'.");
    return 2;
}

if (!File.Exists(manifestPath))
{
    Console.Error.WriteLine($"Manifest not found: {manifestPath}");
    return 2;
}

Manifest manifest;
try { manifest = Manifest.Load(manifestPath); }
catch (Exception e)
{
    Console.Error.WriteLine($"plugins.yaml does not parse: {e.Message}");
    return 2;
}

var report = new Report();
var bundle = new Bundle(repo, manifest, report);
string lockPath = Path.Combine(repo, "plugins.lock.json");

if (command == "lock")
{
    if (!args.Contains("--init"))
    {
        Console.Error.WriteLine("Usage: lock --init   (records the files installed now; does not overwrite an existing lock without --force)");
        return 2;
    }
    if (File.Exists(lockPath) && !args.Contains("--force"))
    {
        Console.Error.WriteLine("plugins.lock.json already exists. Use --force to replace it (or --component <name> --force for one entry).");
        return 2;
    }
    var baseline = Lockfile.Baseline(bundle);
    if (Arg("--component") is string only)
    {
        // Re-record one component (e.g. after reverting its files by hand), keep every other entry.
        var existing = Lockfile.Load(lockPath);
        string? key = baseline.Components.Keys.FirstOrDefault(k => k.Equals(only, StringComparison.OrdinalIgnoreCase));
        if (key == null) { Console.Error.WriteLine($"No component '{only}' in plugins.yaml"); return 2; }
        existing.Components[key] = baseline.Components[key];
        existing.Save(lockPath);
        Console.WriteLine($"Re-recorded {key}: {baseline.Components[key].Files.Count} files");
        return 0;
    }
    baseline.Save(lockPath);
    Console.WriteLine($"Wrote {lockPath}: {baseline.Components.Count} components, {baseline.Components.Values.Sum(e => e.Files.Count)} files");
    return 0;
}

if (command == "update")
{
    var options = new UpdateOptions
    {
        DryRun = args.Contains("--dry-run"),
        NoDownload = args.Contains("--no-download"),
        Only = Arg("--component"),
        WorkDir = Arg("--work-dir") ?? Path.Combine(Path.GetTempPath(), "cs2-plugin-updates"),
        SummaryPath = Arg("--summary"),
        Prune = args.Contains("--prune"),
        FromZip = Arg("--from-zip") is string zip ? Path.GetFullPath(zip) : null,
        FromZipVersion = Arg("--version"),
    };
    if (options.FromZip != null && (options.Only == null || options.FromZipVersion == null || !File.Exists(options.FromZip)))
    {
        Console.Error.WriteLine("--from-zip needs an existing zip, --component <name> and --version <version>");
        return 2;
    }
    List<PlanItem> items;
    try { items = await new Updater(bundle, manifestPath, lockPath, options).RunAsync(); }
    catch (InvalidOperationException e)
    {
        Console.Error.WriteLine(e.Message);
        return 2;
    }

    Console.WriteLine(options.DryRun ? "DRY RUN: nothing was written." : "Updates written to the repo (not committed).");
    Console.WriteLine();
    foreach (var i in items.OrderBy(i => i.Status).ThenBy(i => i.Component.Name))
    {
        string changes = i.Status == "update" && !options.NoDownload ? $"  +{i.Added} ~{i.Changed} -{i.Removed} ={i.Unchanged}" : "";
        Console.WriteLine($"{i.Status,-8} {i.Component.Name,-32} {i.Component.Version,-18} -> {i.Latest,-18} {i.Asset?.Name}{changes}");
        foreach (string n in i.Notes.Distinct()) Console.WriteLine($"{"",-9}- {n}");
        if (i.NotInstalled.Count > 0)
        {
            Console.WriteLine($"{"",-9}- {i.NotInstalled.Count} file(s) in the release are not installed (no path maps them)");
            foreach (string f in i.NotInstalled) Console.WriteLine($"{"",-11}! {f}");
        }
        if (i.PossiblyStale.Count > 0)
        {
            Console.WriteLine($"{"",-9}- {i.PossiblyStale.Count} file(s) from before the lock are not in the new release (left in place)");
            if (verbose)
                foreach (string f in i.PossiblyStale) Console.WriteLine($"{"",-11}{f}");
        }
    }
    if (github && Environment.GetEnvironmentVariable("GITHUB_STEP_SUMMARY") is string s && s.Length > 0)
        File.AppendAllText(s, Updater.Summary(items));
    return items.Any(i => i.Status == "error") ? 1 : 0;
}

Checks.Run(bundle);

if (github) report.WriteGitHub();
if (Arg("--markdown") is string md) report.WriteMarkdown(md);
report.WriteConsole(verbose);

int errors = report.Count(Severity.Error) + (strict ? report.Count(Severity.Warning) : 0);
return errors > 0 ? 1 : 0;

string? Arg(string name)
{
    int i = Array.IndexOf(args, name);
    return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
}

static string FindRepoRoot(string start)
{
    for (var dir = new DirectoryInfo(start); dir != null; dir = dir.Parent)
        if (File.Exists(Path.Combine(dir.FullName, "plugins.yaml")) || Directory.Exists(Path.Combine(dir.FullName, ".git")))
            return dir.FullName;
    return start;
}
