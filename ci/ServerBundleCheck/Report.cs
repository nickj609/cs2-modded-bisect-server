using System.Text;

namespace ServerBundleCheck;

public enum Severity { Error, Warning, Info }

public sealed record Finding(Severity Severity, string Check, string Message, string? File = null);

public sealed class Report
{
    private readonly List<Finding> _findings = new();
    public IReadOnlyList<Finding> Findings => _findings;

    public void Error(string check, string message, string? file = null) => _findings.Add(new(Severity.Error, check, message, file));
    public void Warn(string check, string message, string? file = null) => _findings.Add(new(Severity.Warning, check, message, file));
    public void Info(string check, string message, string? file = null) => _findings.Add(new(Severity.Info, check, message, file));

    public int Count(Severity s) => _findings.Count(f => f.Severity == s);

    public void WriteConsole(bool verbose)
    {
        foreach (var group in _findings.Where(f => verbose || f.Severity != Severity.Info).GroupBy(f => f.Check))
        {
            Console.WriteLine($"== {group.Key}");
            foreach (var f in group.OrderBy(f => f.Severity))
            {
                string tag = f.Severity switch { Severity.Error => "ERROR", Severity.Warning => "warn ", _ => "info " };
                Console.WriteLine($"  {tag} {f.Message}{(f.File != null ? $"  [{f.File}]" : "")}");
            }
        }
        Console.WriteLine();
        Console.WriteLine($"{Count(Severity.Error)} error(s), {Count(Severity.Warning)} warning(s)");
    }

    // GitHub Actions: annotations on the PR and a table in the job summary.
    public void WriteGitHub()
    {
        foreach (var f in _findings.Where(f => f.Severity != Severity.Info))
        {
            string level = f.Severity == Severity.Error ? "error" : "warning";
            string file = f.File != null ? $" file={f.File}," : " ";
            Console.WriteLine($"::{level}{file}title={Escape(f.Check)}::{Escape(f.Message)}");
        }

        string? summary = Environment.GetEnvironmentVariable("GITHUB_STEP_SUMMARY");
        if (!string.IsNullOrEmpty(summary)) File.AppendAllText(summary, Markdown());
    }

    // The findings as a Markdown section (job summary, PR description).
    public void WriteMarkdown(string path) => File.WriteAllText(path, Markdown());

    private string Markdown()
    {
        var sb = new StringBuilder();
        sb.AppendLine("## Server bundle check");
        sb.AppendLine();
        sb.AppendLine($"**{Count(Severity.Error)} error(s), {Count(Severity.Warning)} warning(s)**");
        sb.AppendLine();
        if (_findings.Any(f => f.Severity != Severity.Info))
        {
            sb.AppendLine("| | Check | Finding | File |");
            sb.AppendLine("| --- | --- | --- | --- |");
            foreach (var f in _findings.Where(f => f.Severity != Severity.Info).OrderBy(f => f.Severity).ThenBy(f => f.Check))
                sb.AppendLine($"| {(f.Severity == Severity.Error ? "❌" : "⚠️")} | {f.Check} | {f.Message.Replace("|", "\\|")} | {f.File ?? ""} |");
        }
        return sb.ToString();
    }

    private static string Escape(string s) => s.Replace("%", "%25").Replace("\r", "%0D").Replace("\n", "%0A");
}
