using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

internal static class LocalResumeServer
{
    private static string root;
    private static string log;
    private static readonly object logLock = new object();

    private static void Log(string value)
    {
        lock (logLock) File.AppendAllText(log, value + Environment.NewLine, new UTF8Encoding(false));
    }

    private static int Main(string[] args)
    {
        root = Path.GetFullPath(args[0]);
        log = args[1];
        TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        File.WriteAllText(args[2], ((IPEndPoint)listener.LocalEndpoint).Port.ToString());
        while (true)
        {
            TcpClient client = listener.AcceptTcpClient();
            ThreadPool.QueueUserWorkItem(delegate { Serve(client); });
        }
    }

    private static void Serve(TcpClient client)
    {
        string requestPath = "unknown";
        long transferred = 0;
        try
        {
            client.SendTimeout = 4000;
            client.ReceiveTimeout = 4000;
            using (client)
            using (NetworkStream stream = client.GetStream())
            {
                MemoryStream header = new MemoryStream();
                while (header.Length < 16384)
                {
                    int next = stream.ReadByte();
                    if (next < 0) return;
                    header.WriteByte((byte)next);
                    byte[] bytes = header.GetBuffer();
                    int count = (int)header.Length;
                    if (count >= 4 && bytes[count - 4] == 13 && bytes[count - 3] == 10 && bytes[count - 2] == 13 && bytes[count - 1] == 10) break;
                }
                string text = Encoding.ASCII.GetString(header.ToArray());
                string[] first = text.Split(new string[] { "\r\n" }, StringSplitOptions.None)[0].Split(' ');
                string method = first[0];
                requestPath = Uri.UnescapeDataString(first[1].Split('?')[0]);
                string relative = requestPath.TrimStart('/');
                bool broken = relative.StartsWith("broken/", StringComparison.Ordinal);
                if (broken) relative = "hls/" + relative.Substring(7);
                if (relative == "range.mp4") relative = "source.mp4";
                string file = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
                bool exists = file.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) && File.Exists(file) && !(broken && relative.EndsWith("seg002.ts", StringComparison.Ordinal));
                if (!exists)
                {
                    byte[] missing = Encoding.ASCII.GetBytes("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                    stream.Write(missing, 0, missing.Length);
                    Log("REQUEST " + method + " " + requestPath + " status=404");
                    return;
                }
                long length = new FileInfo(file).Length;
                long start = 0;
                long end = length - 1;
                Match range = Regex.Match(text, @"(?im)^Range:\s*bytes=(\d+)-(\d*)\s*$");
                bool partial = range.Success;
                if (partial)
                {
                    start = long.Parse(range.Groups[1].Value);
                    if (range.Groups[2].Value.Length > 0) end = Math.Min(end, long.Parse(range.Groups[2].Value));
                }
                if (start >= length || end < start)
                {
                    byte[] invalid = Encoding.ASCII.GetBytes("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */" + length + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                    stream.Write(invalid, 0, invalid.Length);
                    return;
                }
                string mime = file.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase) ? "application/vnd.apple.mpegurl" : file.EndsWith(".ts", StringComparison.OrdinalIgnoreCase) ? "video/mp2t" : "video/mp4";
                StringBuilder response = new StringBuilder();
                response.Append(partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n");
                response.Append("Content-Type: ").Append(mime).Append("\r\nContent-Length: ").Append(end - start + 1).Append("\r\nAccept-Ranges: bytes\r\nConnection: close\r\n");
                if (partial) response.Append("Content-Range: bytes ").Append(start).Append('-').Append(end).Append('/').Append(length).Append("\r\n");
                response.Append("\r\n");
                byte[] responseBytes = Encoding.ASCII.GetBytes(response.ToString());
                stream.Write(responseBytes, 0, responseBytes.Length);
                Log("REQUEST " + method + " " + requestPath + " status=" + (partial ? "206" : "200") + " start=" + start);
                if (method == "HEAD") return;
                using (FileStream input = File.OpenRead(file))
                {
                    input.Position = start;
                    byte[] buffer = new byte[8192];
                    while (transferred < end - start + 1)
                    {
                        int count = input.Read(buffer, 0, (int)Math.Min(buffer.Length, end - start + 1 - transferred));
                        if (count == 0) break;
                        stream.Write(buffer, 0, count);
                        stream.Flush();
                        transferred += count;
                        if (!file.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase)) Thread.Sleep(20);
                    }
                }
                Log("COMPLETE " + requestPath + " bytes=" + transferred);
            }
        }
        catch (IOException) { Log("ABORT " + requestPath + " bytes=" + transferred); }
        catch (SocketException) { Log("ABORT " + requestPath + " bytes=" + transferred); }
        catch (Exception exception) { Log("ERROR " + requestPath + " " + exception.GetType().Name); try { client.Close(); } catch { } }
    }
}
