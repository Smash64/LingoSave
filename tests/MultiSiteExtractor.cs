using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Web.Script.Serialization;
public class MultiSiteExtractor {
 static readonly JavaScriptSerializer Json=new JavaScriptSerializer {MaxJsonLength=64*1024*1024};
 static string Arg(string[] a,string k){for(int i=0;i<a.Length-1;i++)if(a[i]==k)return a[i+1];return "";}
 static string Quote(string value){var b=new StringBuilder("\"");int n=0;foreach(char c in value){if(c=='\\'){n++;continue;}if(c=='\"'){b.Append('\\',n*2+1);b.Append(c);n=0;continue;}b.Append('\\',n);n=0;b.Append(c);}b.Append('\\',n*2);b.Append('"');return b.ToString();}
 public static int Main(string[] args){try{
  Console.OutputEncoding=new UTF8Encoding(false);
  if(args.Contains("--version")){Console.WriteLine("multi-site-test-1");return 0;}
  if(args.Contains("--dump-single-json")&&String.IsNullOrEmpty(Arg(args,"--load-info-json"))){
   string url=args.Last();var uri=new Uri(url);
   if(uri.Host.EndsWith("vimeo.com")&&uri.AbsolutePath.Contains("/album/")){
    Console.WriteLine(Json.Serialize(new Dictionary<string,object>{{"_type","playlist"},{"id","vimeo-list"},{"title","Vimeo"},{"entries",new object[]{new Dictionary<string,object>{{"id","1000000001"},{"title","First Vimeo clip"},{"ie_key","Vimeo"}},new Dictionary<string,object>{{"id","1000000002"},{"title","Second Vimeo clip"},{"ie_key","Vimeo"}}}}}));return 0;
   }
   var info=Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Environment.GetEnvironmentVariable("LINGOSAVE_FAKE_RESOURCE_FIXTURE"),Encoding.UTF8));
   info["id"]=uri.Host.Replace('.','-')+uri.AbsolutePath.Trim('/').Replace('/','-');info["title"]=uri.Host+" Sample "+uri.Segments.Last().Trim('/');info["webpage_url"]=url;info["extractor_key"]="Generic";info["extractor"]="generic";
   foreach(Dictionary<string,object> f in (System.Collections.IEnumerable)info["formats"])if(!f.ContainsKey("url"))f["url"]="http://127.0.0.1:1/format";
   Console.WriteLine(Json.Serialize(info));return 0;
  }
  var p=new Process();p.StartInfo.FileName=Environment.GetEnvironmentVariable("LINGOSAVE_MULTI_BASE_EXE");p.StartInfo.Arguments=String.Join(" ",args.Select(Quote));p.StartInfo.UseShellExecute=false;p.StartInfo.CreateNoWindow=true;p.StartInfo.RedirectStandardOutput=true;p.StartInfo.RedirectStandardError=true;p.StartInfo.StandardOutputEncoding=Encoding.UTF8;p.StartInfo.StandardErrorEncoding=Encoding.UTF8;
  p.Start();var stdout=p.StandardOutput.ReadToEndAsync();var stderr=p.StandardError.ReadToEndAsync();p.WaitForExit();Console.Write(stdout.Result);Console.Error.Write(stderr.Result);return p.ExitCode;
 }catch(Exception error){Console.Error.WriteLine("ERROR: multi-site fixture "+error.Message);return 1;}}
}