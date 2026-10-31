namespace ServerBundleCheck;

// Prints what is installed, read from the DLLs: used to write and refresh plugins.yaml by hand.
public static class Inventory
{
    public static void Print(string repo, string gameDir)
    {
        string css = Path.Combine(repo, gameDir, "addons", "counterstrikesharp");
        var api = AssemblyInspector.Read(Path.Combine(css, "api", "CounterStrikeSharp.API.dll"));
        Console.WriteLine($"CounterStrikeSharp.API {api?.Version} ({api?.InformationalVersion}) {api?.TargetFramework}");
        Console.WriteLine();
        Console.WriteLine("folder | dll | ModuleName | ModuleVersion | MinApi | TFM | CSS ref");

        foreach (string root in new[] { "plugins", Path.Combine("plugins", "disabled"), "shared" })
        {
            string dir = Path.Combine(css, root);
            if (!Directory.Exists(dir)) continue;
            foreach (string folder in Directory.GetDirectories(dir).OrderBy(d => d, StringComparer.OrdinalIgnoreCase))
            {
                string name = Path.GetFileName(folder);
                if (root == "plugins" && name == "disabled") continue;
                string main = Path.Combine(folder, name + ".dll");
                var candidates = File.Exists(main) ? new[] { main } : Directory.GetFiles(folder, "*.dll");
                foreach (string dll in candidates)
                {
                    AssemblyInfo? info;
                    try { info = AssemblyInspector.Read(dll); }
                    catch (Exception e) { Console.WriteLine($"{root}/{name} | {Path.GetFileName(dll)} | unreadable: {e.Message}"); continue; }
                    if (info == null || (root != "shared" && !info.IsPlugin && candidates.Length > 1)) continue;
                    var cssRef = info.References.FirstOrDefault(r => r.Name == "CounterStrikeSharp.API");
                    Console.WriteLine($"{root.Replace('\\', '/')}/{name} | {Path.GetFileName(dll)} | {info.ModuleName} | {info.ModuleVersion} | {info.MinimumApiVersion} | {info.TargetFramework} | {(cssRef.Name != null ? cssRef.Version.ToString() : "")}");
                }
            }
        }
    }
}
