using System;
using System.Text;
using System.Threading;

internal static class FakePreviewExtractor
{
    private static int Main(string[] args)
    {
        foreach (string value in args)
        {
            if (value == "--version")
            {
                Console.WriteLine("test-preview-1");
                return 0;
            }
        }

        string url = args.Length == 0 ? string.Empty : args[args.Length - 1];
        if (url.Contains("hang"))
        {
            Thread.Sleep(60000);
        }
        if (url.Contains("playlist"))
        {
            StringBuilder json = new StringBuilder();
            json.Append("{\"_type\":\"playlist\",\"title\":\"Fixture playlist\",\"playlist_count\":25,\"entries\":[");
            for (int index = 1; index <= 20; index++)
            {
                if (index > 1) json.Append(',');
                json.Append("{\"id\":\"id").Append(index).Append("\",\"title\":\"Video ").Append(index).Append("\"}");
            }
            json.Append("]}");
            Console.WriteLine(json.ToString());
        }
        else
        {
            Console.WriteLine("{\"id\":\"single\",\"title\":\"Fixture video\"}");
        }
        return 0;
    }
}
