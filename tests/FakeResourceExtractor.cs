using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

public class FakeResourceExtractor {
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
    static string Arg(string[] args, string name) { for (int i = 0; i < args.Length - 1; i++) if (args[i] == name) return args[i + 1]; return ""; }
    static bool Has(string[] args, string name) { return args.Contains(name); }
    static void Log(string text) { string path = Environment.GetEnvironmentVariable("LINGOSAVE_FAKE_RESOURCE_LOG"); if (!String.IsNullOrEmpty(path)) { using (Mutex gate = new Mutex(false, "Local\\LingoSaveAcceptanceResourceLog")) { bool held = false; try { try { held = gate.WaitOne(5000); } catch (AbandonedMutexException) { held = true; } if (!held) throw new IOException("fixture log lock timeout"); File.AppendAllText(path, text + "\n", Encoding.UTF8); } finally { if (held) gate.ReleaseMutex(); } } } }
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
        string path = String.IsNullOrEmpty(loaded) ? Environment.GetEnvironmentVariable("LINGOSAVE_FAKE_RESOURCE_FIXTURE") : loaded;
        string json = File.ReadAllText(path, Encoding.UTF8);
        if (String.IsNullOrEmpty(loaded) && url.Contains("acceptance-002")) json = json.Replace("arte-acceptance-001", "arte-acceptance-002").Replace("Multilingual acceptance fixture", "Multilingual second fixture");
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
        if (exe.Contains("ffprobe")) {
            string last = args.Length > 0 ? args.Last().ToLowerInvariant() : "";
            Console.WriteLine(last.EndsWith(".mp3") || last.EndsWith(".m4a") || last.EndsWith(".opus") ? "{\"streams\":[{\"codec_type\":\"audio\"}]}" : "{\"streams\":[{\"codec_type\":\"video\"},{\"codec_type\":\"audio\"}]}");
            return 0;
        }
        if (exe == "ffmpeg") {
            string output = args.Last(); int delay; if(Int32.TryParse(Environment.GetEnvironmentVariable("LINGOSAVE_FAKE_PROCESSING_MS"), out delay) && delay > 0) Thread.Sleep(delay); Directory.CreateDirectory(Path.GetDirectoryName(output));
            File.WriteAllBytes(output, Encoding.ASCII.GetBytes("synthetic acceptance processed media"));
            return 0;
        }
        if (!Has(args, "--no-config") || !Has(args, "--no-colors")) { Console.Error.WriteLine("ERROR: base options were packed into a single argument"); return 6; }
        string url = args.Length > 0 ? args.Last() : "";
        if (Has(args, "--dump-single-json") && String.IsNullOrEmpty(Arg(args, "--load-info-json")) && url.Contains("playlist")) {
            Log("inspect|" + url);
            Console.WriteLine("{\"_type\":\"playlist\",\"id\":\"acceptance-list\",\"entries\":[{\"id\":\"arte-acceptance-001\",\"url\":\"https://www.arte.tv/en/videos/acceptance-001/\"},{\"id\":\"arte-acceptance-002\",\"url\":\"https://www.arte.tv/en/videos/acceptance-002/\"}]}"); return 0;
        }
        Dictionary<string, object> info = Info(args, url);
        if (!String.IsNullOrEmpty(Arg(args, "--load-info-json"))) url = Value(info, "webpage_url");
        if (Has(args, "--dump-single-json")) {
            if (String.IsNullOrEmpty(Arg(args, "--load-info-json"))) Log("inspect|" + url);
            else { Dictionary<string, object>[] selected = Select(info, Arg(args, "--format")); info["requested_formats"] = selected; }
            Console.WriteLine(Json.Serialize(info)); return 0;
        }
        string outputDir = Arg(args, "--paths");
        if (String.IsNullOrEmpty(outputDir)) { Console.Error.WriteLine("ERROR: missing output directory"); return 2; }
        Directory.CreateDirectory(outputDir);
        string format = Arg(args, "--format");
        Dictionary<string, object> selectedFormat = Formats(info).FirstOrDefault(f => Value(f, "format_id") == format);
        string type = Has(args, "--skip-download") ? "subtitle" : (Has(args, "--extract-audio") || (selectedFormat != null && Value(selectedFormat, "vcodec") == "none") ? "audio" : "video");
        string key = type == "subtitle" ? (Has(args, "--write-auto-subs") ? "auto" : "provided") + ":" + Arg(args, "--sub-langs") : format;
        Log("download|" + url + "|" + type + "|" + key);
        string failOnce = Environment.GetEnvironmentVariable("LINGOSAVE_FAKE_FAIL_ONCE");
        if (!String.IsNullOrEmpty(failOnce) && type == "audio" && format == "audio-de-dub" && !File.Exists(failOnce)) { File.WriteAllText(failOnce, "failed once"); Console.Error.WriteLine("ERROR: intentional first download failure"); return 3; }
        Console.WriteLine("__LINGO_PROGRESS__50.0%|1024|500|1000|NA|5"); Thread.Sleep(Environment.GetEnvironmentVariable("LINGOSAVE_FAKE_STAGGER_NETWORK") == "1" && url.Contains("acceptance-002") ? 850 : 450);
        string name;
        if (type == "subtitle") {
            string raw = Regex.Unescape(Arg(args, "--sub-langs").Trim('^', '$')); name = Arg(args, "--output").Split('.')[0] + "." + raw + ".srt";
            File.WriteAllText(Path.Combine(outputDir, name), "1\n00:00:00,000 --> 00:00:01,000\nAcceptance subtitle\n", Encoding.UTF8);
        } else {
            name = "media." + (selectedFormat == null ? (type == "audio" ? "mp3" : "mkv") : Value(selectedFormat, "ext"));
            File.WriteAllBytes(Path.Combine(outputDir, name), Encoding.ASCII.GetBytes("synthetic acceptance media"));
        }
        Console.WriteLine("__LINGO_PROGRESS__100.0%|2048|1000|1000|NA|0"); return 0;
    }
}