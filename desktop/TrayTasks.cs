using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace LingoSaveDesktop
{
    public sealed class TrayTaskInfo
    {
        public string Title;
        public string Status;
        public double? Progress;
    }

    public sealed class TrayTaskSnapshot
    {
        public readonly List<TrayTaskInfo> Jobs = new List<TrayTaskInfo>();
        public string Message;

        public bool HasActiveJobs
        {
            get { return Jobs.Exists(job => job.Status == "running" || job.Status == "queued" || job.Status == "waiting_network" || job.Status == "pausing"); }
        }

        public static TrayTaskSnapshot FromJson(string json)
        {
            var parser = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 };
            var data = parser.DeserializeObject(json) as Dictionary<string, object>;
            object value;
            if (data == null || !data.TryGetValue("jobs", out value) || !(value is IEnumerable) || value is string)
                throw new FormatException("The task service returned an invalid summary.");
            var snapshot = new TrayTaskSnapshot();
            foreach (object entry in (IEnumerable)value)
            {
                var job = entry as Dictionary<string, object>;
                if (job == null) continue;
                string status = Text(job, "status");
                if (status != "running" && status != "queued" && status != "waiting_network" && status != "pausing" && status != "paused") continue;
                string title = Text(job, "currentTitle");
                if (String.IsNullOrWhiteSpace(title)) title = Text(job, "title");
                if (String.IsNullOrWhiteSpace(title)) title = "下载任务";
                double? progress = null;
                if (job.TryGetValue("progress", out value) && value != null)
                {
                    double parsed;
                    if (Double.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out parsed) && !Double.IsNaN(parsed) && !Double.IsInfinity(parsed))
                        progress = Math.Max(0.0, Math.Min(1.0, parsed));
                }
                snapshot.Jobs.Add(new TrayTaskInfo { Title = Regex.Replace(title, @"[\r\n\t]+", " "), Status = status, Progress = progress });
            }
            return snapshot;
        }

        private static string Text(Dictionary<string, object> data, string key)
        {
            object value;
            return data.TryGetValue(key, out value) && value != null ? Convert.ToString(value, CultureInfo.InvariantCulture) : null;
        }
    }

    public static class TrayTaskMenu
    {
        public static void Populate(ContextMenuStrip menu, TrayTaskSnapshot snapshot, Action open, Action exit)
        {
            while (menu.Items.Count > 0) { var item = menu.Items[0]; menu.Items.RemoveAt(0); item.Dispose(); }
            snapshot = snapshot ?? new TrayTaskSnapshot { Message = "正在读取任务…" };
            menu.Items.Add(new ToolStripMenuItem("当前任务（" + snapshot.Jobs.Count + "）") { Enabled = false });
            if (snapshot.Jobs.Count == 0)
                menu.Items.Add(new ToolStripMenuItem(snapshot.Message ?? "暂无进行中的任务") { Enabled = false });
            int visible = Math.Min(6, snapshot.Jobs.Count);
            for (int index = 0; index < visible; index++)
            {
                TrayTaskInfo job = snapshot.Jobs[index];
                string progress = job.Progress.HasValue ? " " + (job.Progress.Value * 100.0).ToString("0.#", CultureInfo.InvariantCulture) + "%" : "";
                int[] titleElements = StringInfo.ParseCombiningCharacters(job.Title);
                string title = titleElements.Length > 32 ? job.Title.Substring(0, titleElements[32]) + "…" : job.Title;
                var row = new ToolStripMenuItem(StatusLabel(job.Status) + progress + " · " + title.Replace("&", "&&"));
                row.ToolTipText = job.Title;
                row.Click += delegate { open(); };
                menu.Items.Add(row);
            }
            if (snapshot.Jobs.Count > visible)
                menu.Items.Add("还有 " + (snapshot.Jobs.Count - visible) + " 项，打开应用查看", null, delegate { open(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("打开 LingoSave", null, delegate { open(); });
            var quit = new ToolStripMenuItem("退出");
            quit.ToolTipText = "退出应用并停止后台下载服务";
            quit.Click += delegate { exit(); };
            menu.Items.Add(quit);
        }

        private static string StatusLabel(string status)
        {
            switch (status)
            {
                case "running": return "下载中";
                case "queued": return "排队中";
                case "waiting_network": return "等待重连";
                case "pausing": return "正在暂停";
                case "paused": return "已暂停";
                default: return "下载任务";
            }
        }
    }
}
