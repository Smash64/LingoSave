using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

public class FakeResumableExtractor {
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
    static string Arg(string[] args, string name) { for (int i = 0; i < args.Length - 1; i++) if (args[i] == name) return args[i + 1]; return ""; }
    static bool Has(string[] args, string name) { return args.Contains(name); }
    static void Log(string text) { string path = Environment.GetEnvironmentVariable("LINGO_STABILITY_LOG"); if (!String.IsNullOrEmpty(path)) File.AppendAllText(path, text + "\n", Encoding.UTF8); }
    static string Value(Dictionary<string, object> item, string key) { object value; return item.TryGetValue(key, out value) && value != null ? Convert.ToString(value) : ""; }
    static Dictionary<string, object>[] Formats(Dictionary<string, object> info) { return ((System.Collections.IEnumerable)info["formats"]).Cast<Dictionary<string, object>>().ToArray(); }
    static Dictionary<string, object>[] Select(Dictionary<string, object> info, string expression) {
        Dictionary<string, object>[] formats = Formats(info);
        if (expression.Contains("bestvideo")) {
            Match ceiling = Regex.Match(expression, @"height<=(\d+)"); int height = ceiling.Success ? int.Parse(ceiling.Groups[1].Value) : Int32.MaxValue;
            Dictionary<string, object> video = formats.Where(f => Value(f, "vcodec") != "none" && Value(f, "acodec") == "none" && (!f.ContainsKey("height") || Convert.ToInt32(f["height"]) <= height)).OrderByDescending(f => f.ContainsKey("height") ? Convert.ToInt32(f["height"]) : 0).First();
            string audioId = expression.Split('+').Last().Split('/')[0];
            Dictionary<string, object> audio = formats.FirstOrDefault(f => Value(f, "format_id") == audioId) ?? formats.First(f => Value(f, "vcodec") == "none");
            return new[] { video, audio };
        }
        Dictionary<string, object> exact = formats.FirstOrDefault(f => Value(f, "format_id") == expression);
        return new[] { exact ?? formats.First(f => Value(f, "vcodec") != "none") };
    }
    static Dictionary<string, object> Info(string[] args, string url) {
        string loaded = Arg(args, "--load-info-json");
        string path = String.IsNullOrEmpty(loaded) ? Environment.GetEnvironmentVariable("LINGO_STABILITY_FIXTURE") : loaded;
        string json = File.ReadAllText(path, Encoding.UTF8);
        if (String.IsNullOrEmpty(loaded) && url.Contains("stability-002")) json = json.Replace("arte-acceptance-001", "arte-acceptance-002").Replace("Multilingual acceptance fixture", "Multilingual second fixture");
        Dictionary<string, object> info = Json.Deserialize<Dictionary<string, object>>(json);
        if (String.IsNullOrEmpty(loaded)) info["webpage_url"] = url;
        foreach (Dictionary<string, object> format in Formats(info)) {
            if (!format.ContainsKey("url")) format["url"] = "http://127.0.0.1:1/" + Value(format, "format_id");
            if (!format.ContainsKey("ext")) format["ext"] = Value(format, "vcodec") == "none" ? "m4a" : "mp4";
        }
        return info;
    }
    public static int Main(string[] args) { try { return Run(args); } catch(Exception e) { Console.Error.WriteLine("ERROR: fixture " + e.GetType().Name + ": " + e.Message); return 91; } }
    static int Run(string[] args) {
        Console.OutputEncoding = new UTF8Encoding(false);
        string exe = Path.GetFileNameWithoutExtension(System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName).ToLowerInvariant();
        string scenario = Environment.GetEnvironmentVariable("LINGO_STABILITY_SCENARIO") ?? "";
        string marker = Environment.GetEnvironmentVariable("LINGO_STABILITY_MARKER");
        if (exe.Contains("ffprobe")) {
            string last = args.Last().ToLowerInvariant();
            Console.WriteLine(last.EndsWith(".mp3") || last.EndsWith(".m4a") || last.EndsWith(".opus") ? "{\"streams\":[{\"codec_type\":\"audio\"}]}" : "{\"streams\":[{\"codec_type\":\"video\"},{\"codec_type\":\"audio\"}]}"); return 0;
        }
        if (exe == "ffmpeg") {
            if (scenario == "merge-pause") Thread.Sleep(1500);
            string output = args.Last(); Directory.CreateDirectory(Path.GetDirectoryName(output)); File.WriteAllBytes(output, new byte[12000]); return 0;
        }
        string url = args.Last();
        if (Has(args, "--dump-single-json") && String.IsNullOrEmpty(Arg(args, "--load-info-json"))) {
            Log("INSPECT|" + url);
            if (scenario == "source-fail-once" && !File.Exists(marker)) { File.WriteAllText(marker, "1"); Console.Error.WriteLine("ERROR: source unavailable"); return 1; }
            if (url.Contains("playlist")) {
                Console.WriteLine("{\"_type\":\"playlist\",\"id\":\"stable-list\",\"entries\":[{\"id\":\"arte-acceptance-001\",\"url\":\"https://www.arte.tv/en/videos/stability-001/\"},{\"id\":\"arte-acceptance-002\",\"url\":\"https://www.arte.tv/en/videos/stability-002/\"}]}"); return 0;
            }
        }
        Dictionary<string, object> info = Info(args, url);
        if (!String.IsNullOrEmpty(Arg(args, "--load-info-json"))) url = Value(info, "webpage_url");
        if (Has(args, "--dump-single-json")) {
            if (!String.IsNullOrEmpty(Arg(args, "--load-info-json"))) info["requested_formats"] = Select(info, Arg(args, "--format"));
            Console.WriteLine(Json.Serialize(info)); return 0;
        }
        if (!Has(args, "--continue") || !Has(args, "--part") || !Has(args, "--abort-on-unavailable-fragments") || Arg(args, "--concurrent-fragments") != "4") {
            Console.Error.WriteLine("ERROR: required stable download options are missing"); return 5;
        }
        string format = Arg(args, "--format");
        Dictionary<string, object> selected = Formats(info).FirstOrDefault(f => Value(f, "format_id") == format);
        string type = Has(args, "--skip-download") ? "subtitle" : (Has(args, "--extract-audio") || (selected != null && Value(selected, "vcodec") == "none") ? "audio" : "video");
        bool legacy = Has(args, "--download-archive");
        if (legacy) Console.WriteLine("__LINGOSAVE_BEGIN__\"arte-acceptance-001\"|\"Resumable fixture\"|\"" + url + "\"");
        string dir = Arg(args, "--paths"); Directory.CreateDirectory(dir);
        string part = Path.Combine(dir, "media.part");
        long offset = File.Exists(part) ? new FileInfo(part).Length : 0;
        Log("DOWNLOAD|" + url + "|" + type + "|" + format + "|START=" + offset);
        if (scenario == "always-network" && offset >= 3000) { Console.Error.WriteLine("ERROR: connection reset by peer"); return 1; }
        using (FileStream stream = new FileStream(part, FileMode.Append, FileAccess.Write, FileShare.Read)) {
            for (long count = offset; count < 12000; count += 1000) {
                stream.Write(new byte[1000], 0, 1000); stream.Flush(true);
                Console.WriteLine((legacy ? "__LINGOSAVE_PROGRESS__" : "__LINGO_PROGRESS__") + ((count + 1000) * 100.0 / 12000).ToString("F1", System.Globalization.CultureInfo.InvariantCulture) + "%|8000|" + (count + 1000) + "|12000|NA|2");
                if ((scenario == "network-once" || scenario == "always-network") && count >= 2000 && !File.Exists(marker)) { File.WriteAllText(marker, "1"); Console.Error.WriteLine("ERROR: connection timed out"); return 1; }
                Thread.Sleep(110);
            }
        }
        if (legacy) { Console.WriteLine("__LINGOSAVE_PHASE__process"); if (scenario == "merge-pause") Thread.Sleep(1500); }
        string target = Path.Combine(dir, "media." + (legacy || selected == null ? (type == "audio" ? "mp3" : "mkv") : Value(selected, "ext")));
        if (type == "subtitle") {
            string raw = Regex.Unescape(Arg(args, "--sub-langs").Trim('^', '$'));
            target = Path.Combine(dir, Arg(args, "--output").Split('.')[0] + "." + raw + ".srt"); File.WriteAllText(target, "1\n00:00:00,000 --> 00:00:01,000\nResumable fixture\n"); File.Delete(part);
        } else { File.Move(part, target); }
        if (legacy) Console.WriteLine("__LINGOSAVE_DONE__\"arte-acceptance-001\"|\"" + target.Replace("\\", "\\\\") + "\"|\"Resumable fixture\"");
        return 0;
    }
}