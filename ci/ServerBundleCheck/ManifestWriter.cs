using System.Text.RegularExpressions;

namespace ServerBundleCheck;

// Changes single values in plugins.yaml in place, so comments and layout survive (a YAML round trip would drop them).
public static class ManifestWriter
{
    public static bool SetVersion(string path, string component, string version) =>
        SetField(path, component, "version", version);

    public static bool SetField(string path, string component, string field, string value)
    {
        var lines = File.ReadAllLines(path).ToList();
        int start = lines.FindIndex(l => Regex.IsMatch(l, $@"^\s*-\s+name:\s*[""']?{Regex.Escape(component)}[""']?\s*$"));
        if (start < 0) return false;

        int indent = lines[start].IndexOf('-') + 2;
        int end = lines.FindIndex(start + 1, l => Regex.IsMatch(l, @"^\s*-\s+name:"));
        if (end < 0) end = lines.Count;

        string formatted = $"{new string(' ', indent)}{field}: {Quote(value)}";
        for (int i = start + 1; i < end; i++)
        {
            if (Regex.IsMatch(lines[i], $@"^\s{{{indent}}}{Regex.Escape(field)}:"))
            {
                lines[i] = formatted;
                File.WriteAllLines(path, lines);
                return true;
            }
        }
        lines.Insert(start + 1, formatted);
        File.WriteAllLines(path, lines);
        return true;
    }

    // A key of the top-level "server:" block, e.g. css_api.
    public static bool SetServerField(string path, string field, string value)
    {
        var lines = File.ReadAllLines(path);
        for (int i = 0; i < lines.Length; i++)
        {
            var m = Regex.Match(lines[i], $@"^(\s+){Regex.Escape(field)}:\s*[^#]*?(\s*#.*)?$");
            if (!m.Success) continue;
            lines[i] = $"{m.Groups[1].Value}{field}: {Quote(value)}{(m.Groups[2].Success ? "  " + m.Groups[2].Value.Trim() : "")}";
            File.WriteAllLines(path, lines);
            return true;
        }
        return false;
    }

    // Quote values YAML would read as numbers or that contain special characters ("1.10" must stay "1.10").
    private static string Quote(string v) =>
        Regex.IsMatch(v, @"^[0-9.]+$") || Regex.IsMatch(v, @"[:#\[\]{},&*!|>'""%@`]") || v.Length == 0
            ? "\"" + v.Replace("\"", "\\\"") + "\""
            : v;
}
