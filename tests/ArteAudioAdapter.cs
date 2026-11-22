using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Diagnostics;

// Metadata is synthetic ARTE-shaped input. Selection, HLS transfer and media conversion use real tools.
internal static class ArteAudioAdapter
{
    private static string Quote(string value)
    {
        if (value.Length > 0 && value.All(c => !Char.IsWhiteSpace(c) && c != '"')) return value;
        StringBuilder result = new StringBuilder("\"");
        int slashCount = 0;
        foreach (char character in value)
        {
            if (character == '\\') { slashCount++; continue; }
            if (character == '"') { result.Append('\\', slashCount * 2 + 1); result.Append(character); slashCount = 0; continue; }
            result.Append('\\', slashCount); slashCount = 0; result.Append(character);
        }
        result.Append('\\', slashCount * 2); result.Append('"'); return result.ToString();
    }
    private static string Argument(string[] arguments, string name)
    {
        for (int index = 0; index < arguments.Length - 1; index++) if (arguments[index] == name) return arguments[index + 1];
        return "";
    }
    private static int Main(string[] arguments)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        bool inspection = arguments.Contains("--dump-single-json") && !arguments.Contains("--load-info-json");
        string log = Environment.GetEnvironmentVariable("LINGO_ARTE_LOG");
        File.AppendAllText(log, inspection ? "inspect\n" : (arguments.Contains("--dump-single-json") ? "select|" : "download|") + Argument(arguments, "--format") + "\n", new UTF8Encoding(false));
        if (inspection)
        {
            Console.WriteLine(File.ReadAllText(Environment.GetEnvironmentVariable("LINGO_ARTE_FIXTURE"), Encoding.UTF8));
            return 0;
        }
        string[] forwarded = arguments.Concat(new string[] { "--proxy", "" }).ToArray();
        ProcessStartInfo start = new ProcessStartInfo(Environment.GetEnvironmentVariable("LINGO_ARTE_REAL_YT"), String.Join(" ", forwarded.Select(Quote)));
        start.UseShellExecute = false; start.CreateNoWindow = true;
        start.RedirectStandardOutput = true; start.RedirectStandardError = true;
        start.StandardOutputEncoding = Encoding.UTF8; start.StandardErrorEncoding = Encoding.UTF8;
        using (Process process = Process.Start(start))
        {
            var output = process.StandardOutput.ReadToEndAsync(); var errors = process.StandardError.ReadToEndAsync();
            process.WaitForExit(); Console.Write(output.Result); Console.Error.Write(errors.Result); return process.ExitCode;
        }
    }
}