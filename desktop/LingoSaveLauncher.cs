using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;
using System.Text.RegularExpressions;
using System.Text;
using System.Collections.Generic;
using System.Windows.Forms;

namespace LingoSaveDesktop
{
    internal static class Program
    {
        private const string MutexName = "Local\\LingoSaveDesktopClient";
        private const string ActivateEventName = "Local\\LingoSaveDesktopActivate";
        private const string QuitEventName = "Local\\LingoSaveDesktopQuit";

        [STAThread]
        private static void Main(string[] args)
        {
            bool firstInstance;
            using (Mutex singleInstance = new Mutex(true, MutexName, out firstInstance))
            using (EventWaitHandle activate = new EventWaitHandle(false, EventResetMode.AutoReset, ActivateEventName))
            using (EventWaitHandle quit = new EventWaitHandle(false, EventResetMode.AutoReset, QuitEventName))
            {
                if (args.Length > 0 && args[0] == "--quit")
                {
                    if (!firstInstance) quit.Set();
                    return;
                }
                if (!firstInstance)
                {
                    activate.Set();
                    return;
                }

                DesktopBranding.InitializeProcess();
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                try
                {
                    using (LingoContext context = new LingoContext(activate, quit))
                    {
                        Application.Run(context);
                    }
                }
                catch (Exception error)
                {
                    try
                    {
                        string configured = Environment.GetEnvironmentVariable("LINGOSAVE_DATA_DIR");
                        string dataRoot = String.IsNullOrWhiteSpace(configured) ?
                            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LingoSave") :
                            Path.GetFullPath(configured);
                        Directory.CreateDirectory(dataRoot);
                        File.WriteAllText(Path.Combine(dataRoot, "startup-error.log"), error.ToString(), Encoding.UTF8);
                    }
                    catch (Exception) { }
                    MessageBox.Show(error.Message, "无法启动 LingoSave", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                GC.KeepAlive(singleInstance);
            }
        }
    }

    internal sealed class LingoContext : ApplicationContext
    {
        private readonly string root;
        private readonly string browserProfile;
        private readonly NotifyIcon tray;
        private readonly ContextMenuStrip trayMenu;
        private readonly DesktopBranding branding;
        private readonly Icon trayIcon;
        private readonly System.Windows.Forms.Timer activationTimer;
        private readonly EventWaitHandle activate;
        private readonly EventWaitHandle quit;
        private Process server;
        private Process browser;
        private IntPtr browserWindow = IntPtr.Zero;
        private int port;
        private bool exiting;
        private TrayTaskSnapshot traySnapshot;
        private int traySnapshotVersion;
        private int trayAppliedVersion = -1;
        private int trayRefreshPending;
        private DateTime trayNextRefresh = DateTime.MinValue;
        private readonly string launchId = Guid.NewGuid().ToString("N");

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr handle, int command);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr handle);

        private delegate bool WindowEnumerator(IntPtr handle, IntPtr parameter);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(WindowEnumerator callback, IntPtr parameter);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr handle, StringBuilder text, int capacity);

        [DllImport("user32.dll")]
        private static extern int GetWindowTextLength(IntPtr handle);

        [DllImport("user32.dll")]
        private static extern bool IsWindow(IntPtr handle);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr handle);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);

        [DllImport("user32.dll")]
        private static extern bool PostMessage(IntPtr handle, uint message, IntPtr wParam, IntPtr lParam);

        public LingoContext(EventWaitHandle activateEvent, EventWaitHandle quitEvent)
        {
            activate = activateEvent;
            quit = quitEvent;
            root = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory);
            string configuredDataRoot = Environment.GetEnvironmentVariable("LINGOSAVE_DATA_DIR");
            string dataRoot = String.IsNullOrWhiteSpace(configuredDataRoot) ?
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LingoSave") :
                Path.GetFullPath(configuredDataRoot);
            browserProfile = Path.Combine(dataRoot, "BrowserProfile");
            Directory.CreateDirectory(browserProfile);
            branding = new DesktopBranding(root);
            trayIcon = branding.CreateTrayIcon();

            trayMenu = new ContextMenuStrip();
            UpdateTrayMenu();
            trayMenu.Opening += delegate { UpdateTrayMenu(); RefreshTrayTasks(); };
            tray = new NotifyIcon();
            tray.Icon = trayIcon;
            tray.Text = "LingoSave 语影";
            tray.ContextMenuStrip = trayMenu;
            tray.DoubleClick += delegate { OpenWindow(); };
            tray.Visible = true;

            activationTimer = new System.Windows.Forms.Timer();
            activationTimer.Interval = 400;
            activationTimer.Tick += delegate
            {
                if (exiting) return;
                if (quit.WaitOne(0))
                {
                    ExitApplication(true);
                    if (exiting) return;
                }
                if (activate.WaitOne(0)) OpenWindow();
                if (DateTime.UtcNow >= trayNextRefresh) RefreshTrayTasks();
                if (trayAppliedVersion != Volatile.Read(ref traySnapshotVersion))
                {
                    TrayTaskSnapshot snapshot = traySnapshot;
                    tray.Text = snapshot != null && snapshot.Jobs.Count > 0 ? "LingoSave · " + snapshot.Jobs.Count + " 个当前任务" : "LingoSave 语影";
                    if (trayMenu.Visible) UpdateTrayMenu();
                    else trayAppliedVersion = Volatile.Read(ref traySnapshotVersion);
                }
                if (browserWindow != IntPtr.Zero && IsWindow(browserWindow)) branding.Apply(browserWindow);
                if (server != null && server.HasExited && !exiting)
                {
                    activationTimer.Stop();
                    MessageBox.Show("下载服务已停止。请重新启动 LingoSave。", "LingoSave", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    ExitApplication(false);
                }
            };

            try
            {
                StartServer();
                activationTimer.Start();
                OpenWindow();
                try { File.Delete(Path.Combine(dataRoot, "startup-error.log")); } catch (Exception) { }
                tray.ShowBalloonTip(3000, "LingoSave 正在运行", "关闭窗口后，下载服务仍在托盘中运行。", ToolTipIcon.Info);
            }
            catch
            {
                exiting = true;
                activationTimer.Stop();
                tray.Visible = false;
                StopServerTree();
                activationTimer.Dispose();
                tray.Dispose();
                trayMenu.Dispose();
                trayIcon.Dispose();
                branding.Dispose();
                throw;
            }
        }

        private void UpdateTrayMenu()
        {
            TrayTaskMenu.Populate(trayMenu, traySnapshot, OpenWindow, delegate { ExitApplication(true); });
            trayAppliedVersion = Volatile.Read(ref traySnapshotVersion);
        }

        private void RefreshTrayTasks()
        {
            if (exiting || server == null || Interlocked.CompareExchange(ref trayRefreshPending, 1, 0) != 0) return;
            trayNextRefresh = DateTime.UtcNow.AddSeconds(3);
            ThreadPool.QueueUserWorkItem(delegate
            {
                TrayTaskSnapshot snapshot;
                try
                {
                    var request = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + port + "/api/tray");
                    request.Timeout = 1500;
                    request.ReadWriteTimeout = 1500;
                    request.Proxy = null;
                    using (var response = request.GetResponse())
                    using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                        snapshot = TrayTaskSnapshot.FromJson(reader.ReadToEnd());
                }
                catch (Exception)
                {
                    snapshot = new TrayTaskSnapshot { Message = "暂时无法读取任务，点击打开应用查看" };
                }
                traySnapshot = snapshot;
                Interlocked.Increment(ref traySnapshotVersion);
                Interlocked.Exchange(ref trayRefreshPending, 0);
            });
        }

        private void StartServer()
        {
            string script = Path.Combine(root, "run.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("找不到下载服务脚本 run.ps1。", script);
            port = ChoosePort();
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = powershell;
            using (Process parent = Process.GetCurrentProcess())
            {
                info.Arguments = "-NoProfile -ExecutionPolicy Bypass -Sta -File " + Quote(script) +
                    " -Port " + port + " -ParentPid " + parent.Id +
                    " -ParentStartTicks " + parent.StartTime.Ticks + " -LaunchId " + launchId;
            }
            info.WorkingDirectory = root;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            server = Process.Start(info);
            if (server == null) throw new InvalidOperationException("无法启动本机下载服务。");
            DateTime deadline = DateTime.UtcNow.AddSeconds(20);
            while (DateTime.UtcNow < deadline)
            {
                if (server.HasExited) throw new InvalidOperationException("下载服务启动失败。可能已有 LingoSave 服务使用同一数据目录；请关闭旧服务后重试，或检查 PowerShell 运行依赖。");
                if (ServiceResponds()) return;
                Thread.Sleep(200);
            }
            throw new TimeoutException("下载服务启动超时。请检查端口和运行依赖。");
        }

        private int ChoosePort()
        {
            TcpListener listener = null;
            try
            {
                listener = new TcpListener(IPAddress.Loopback, 8765);
                listener.Start();
                return 8765;
            }
            catch (SocketException)
            {
                if (listener != null) listener.Stop();
                listener = new TcpListener(IPAddress.Loopback, 0);
                listener.Start();
                return ((IPEndPoint)listener.LocalEndpoint).Port;
            }
            finally
            {
                if (listener != null) listener.Stop();
            }
        }

        private bool ServiceResponds()
        {
            try
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + port + "/api/health");
                request.Timeout = 500;
                request.ReadWriteTimeout = 500;
                request.Proxy = null;
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                using (StreamReader reader = new StreamReader(response.GetResponseStream()))
                {
                    string body = reader.ReadToEnd();
                    return response.StatusCode == HttpStatusCode.OK &&
                        body.Contains("\"launchId\":\"" + launchId + "\"");
                }
            }
            catch (WebException) { return false; }
        }

        private void OpenWindow()
        {
            if (browserWindow != IntPtr.Zero && IsWindow(browserWindow))
            {
                branding.Apply(browserWindow);
                ShowWindow(browserWindow, 9);
                SetForegroundWindow(browserWindow);
                return;
            }
            if (browser != null)
            {
                try
                {
                    browser.Refresh();
                    if (!browser.HasExited && browser.MainWindowHandle != IntPtr.Zero)
                    {
                        browserWindow = browser.MainWindowHandle;
                        branding.Apply(browserWindow);
                        ShowWindow(browserWindow, 9);
                        SetForegroundWindow(browserWindow);
                        return;
                    }
                }
                catch (InvalidOperationException) { }
            }

            List<IntPtr> existing = FindAppWindows();
            if (browser != null && existing.Count > 0)
            {
                browserWindow = existing[0];
                branding.Apply(browserWindow);
                ShowWindow(browserWindow, 9);
                SetForegroundWindow(browserWindow);
                return;
            }

            string url = "http://127.0.0.1:" + port + "/";
            string edge = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Microsoft\\Edge\\Application\\msedge.exe");
            string edge64 = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Microsoft\\Edge\\Application\\msedge.exe");
            string chrome = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Google\\Chrome\\Application\\chrome.exe");
            string chrome32 = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Google\\Chrome\\Application\\chrome.exe");
            string executable = File.Exists(edge) ? edge : (File.Exists(edge64) ? edge64 : (File.Exists(chrome) ? chrome : (File.Exists(chrome32) ? chrome32 : null)));
            if (executable == null)
            {
                Process.Start(url);
                return;
            }
            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = executable;
            info.Arguments = "--app=" + url + " --user-data-dir=" + Quote(browserProfile) + " --no-first-run --window-size=1180,820";
            info.UseShellExecute = true;
            browser = Process.Start(info);
            DateTime deadline = DateTime.UtcNow.AddSeconds(5);
            while (DateTime.UtcNow < deadline)
            {
                foreach (IntPtr candidate in FindAppWindows())
                {
                    if (!existing.Contains(candidate))
                    {
                        browserWindow = candidate;
                        branding.Apply(browserWindow);
                        return;
                    }
                }
                Thread.Sleep(100);
            }
        }

        private static List<IntPtr> FindAppWindows()
        {
            List<IntPtr> windows = new List<IntPtr>();
            EnumWindows(delegate(IntPtr handle, IntPtr parameter)
            {
                if (!IsWindowVisible(handle)) return true;
                int length = GetWindowTextLength(handle);
                if (length < 9 || length > 300) return true;
                StringBuilder title = new StringBuilder(length + 1);
                GetWindowText(handle, title, title.Capacity);
                if (!title.ToString().StartsWith("LingoSave", StringComparison.OrdinalIgnoreCase)) return true;
                uint processId;
                GetWindowThreadProcessId(handle, out processId);
                try
                {
                    using (Process process = Process.GetProcessById((int)processId))
                    {
                        if (process.ProcessName.Equals("msedge", StringComparison.OrdinalIgnoreCase) ||
                            process.ProcessName.Equals("chrome", StringComparison.OrdinalIgnoreCase)) windows.Add(handle);
                    }
                }
                catch (ArgumentException) { }
                return true;
            }, IntPtr.Zero);
            return windows;
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private bool? HasActiveJobs()
        {
            try
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + port + "/api/tray");
                request.Timeout = 1500;
                request.ReadWriteTimeout = 1500;
                request.Proxy = null;
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                using (StreamReader reader = new StreamReader(response.GetResponseStream()))
                {
                    return TrayTaskSnapshot.FromJson(reader.ReadToEnd()).HasActiveJobs;
                }
            }
            catch (WebException) { return null; }
            catch (FormatException) { return null; }
            catch (ArgumentException) { return null; }
            catch (InvalidOperationException) { return null; }
        }

        private void StopServerTree()
        {
            if (server == null || server.HasExited) return;
            try
            {
                string configuredDataRoot = Environment.GetEnvironmentVariable("LINGOSAVE_DATA_DIR");
                string dataRoot = String.IsNullOrWhiteSpace(configuredDataRoot) ?
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LingoSave") :
                    Path.GetFullPath(configuredDataRoot);
                Directory.CreateDirectory(dataRoot);
                File.WriteAllText(Path.Combine(dataRoot, "shutdown.request"), String.Empty);
                if (server.WaitForExit(6000)) return;
            }
            catch (Exception) { }
            try
            {
                string taskkill = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "taskkill.exe");
                ProcessStartInfo info = new ProcessStartInfo();
                info.FileName = taskkill;
                info.Arguments = "/PID " + server.Id + " /T /F";
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.WindowStyle = ProcessWindowStyle.Hidden;
                using (Process killer = Process.Start(info))
                {
                    if (killer != null) killer.WaitForExit(5000);
                }
                if (!server.HasExited) server.Kill();
            }
            catch (Exception)
            {
                try { if (!server.HasExited) server.Kill(); } catch (InvalidOperationException) { }
            }
        }

        private void ExitApplication(bool confirmActiveJobs)
        {
            if (exiting) return;
            if (confirmActiveJobs)
            {
                bool? activeJobs = HasActiveJobs();
                if (activeJobs != false)
                {
                    string message = activeJobs == true ?
                        "仍有排队或下载中的任务。退出会停止当前下载，下次启动时会尝试恢复。确定退出吗？" :
                        "目前无法查询下载任务状态。退出可能会中断下载，下次启动时会尝试恢复。确定退出吗？";
                    DialogResult answer = MessageBox.Show(message, "退出 LingoSave", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                    if (answer != DialogResult.Yes) return;
                }
            }
            exiting = true;
            activationTimer.Stop();
            tray.Visible = false;
            branding.Detach();
            if (browser != null)
            {
                try
                {
                    if (browserWindow != IntPtr.Zero && IsWindow(browserWindow))
                    {
                        PostMessage(browserWindow, 0x0010, IntPtr.Zero, IntPtr.Zero);
                    }
                    else if (!browser.HasExited)
                    {
                        browser.CloseMainWindow();
                    }
                }
                catch (InvalidOperationException) { }
            }
            StopServerTree();
            ExitThread();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                activationTimer.Dispose();
                tray.Dispose();
                trayMenu.Dispose();
                trayIcon.Dispose();
                branding.Dispose();
                if (browser != null) browser.Dispose();
                if (server != null) server.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
