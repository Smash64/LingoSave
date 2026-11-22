using System;
using System.ComponentModel;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

public static class LingoSaveFileLocation
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHParseDisplayName(string name, IntPtr context, out IntPtr item, uint attributes, out uint found);
    [DllImport("shell32.dll")]
    private static extern int SHOpenFolderAndSelectItems(IntPtr folder, uint count, IntPtr children, uint flags);
    [DllImport("shell32.dll")] private static extern IntPtr ILFindLastID(IntPtr item);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr ShellExecute(IntPtr owner, string operation, string file, string arguments, string directory, int show);
    [DllImport("ole32.dll")] private static extern int CoInitializeEx(IntPtr reserved, uint flags);
    [DllImport("ole32.dll")] private static extern void CoUninitialize();
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr window);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();

    private static void RunWithCom(Action operation)
    {
        Marshal.ThrowExceptionForHR(CoInitializeEx(IntPtr.Zero, 2));
        try { operation(); } finally { CoUninitialize(); }
    }

    private static void RunOnSta(Action operation)
    {
        if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA) { RunWithCom(operation); return; }
        Exception error = null;
        Thread thread = new Thread(delegate() { try { RunWithCom(operation); } catch (Exception e) { error = e; } });
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (error != null) throw error;
    }

    public static void RevealFile(string path)
    {
        path = Path.GetFullPath(path);
        if (!File.Exists(path)) throw new FileNotFoundException("The downloaded file no longer exists.", path);
        RunOnSta(delegate() {
            // Reuse a folder that is already open before asking Explorer to create a view.
            if (ActivateFolder(Path.GetDirectoryName(path), path, false)) return;
            IntPtr item = IntPtr.Zero;
            IntPtr folder = IntPtr.Zero;
            IntPtr children = IntPtr.Zero;
            try {
                uint found;
                Marshal.ThrowExceptionForHR(SHParseDisplayName(path, IntPtr.Zero, out item, 0, out found));
                Marshal.ThrowExceptionForHR(SHParseDisplayName(Path.GetDirectoryName(path), IntPtr.Zero, out folder, 0, out found));
                children = Marshal.AllocCoTaskMem(IntPtr.Size);
                Marshal.WriteIntPtr(children, ILFindLastID(item));
                Marshal.ThrowExceptionForHR(SHOpenFolderAndSelectItems(folder, 1, children, 0));
                if (!ActivateFolder(Path.GetDirectoryName(path), path, true)) throw new IOException("Windows could not find the requested download folder.");
            } finally {
                if (children != IntPtr.Zero) Marshal.FreeCoTaskMem(children);
                if (folder != IntPtr.Zero) Marshal.FreeCoTaskMem(folder);
                if (item != IntPtr.Zero) Marshal.FreeCoTaskMem(item);
            }
        });
    }

    public static void OpenDirectory(string path)
    {
        path = Path.GetFullPath(path);
        if (!Directory.Exists(path)) throw new DirectoryNotFoundException("The original download folder no longer exists.");
        RunOnSta(delegate() {
            if (ActivateFolder(path, null, false)) return;
            // SW_SHOWNORMAL: the folder requested by the user must be visible.
            long result = ShellExecute(IntPtr.Zero, "open", path, null, null, 1).ToInt64();
            if (result <= 32) throw new Win32Exception((int)result, "Windows could not open the download folder.");
            if (!ActivateFolder(path, null, true)) throw new IOException("Windows could not find the requested download folder.");
        });
    }

    private static object Property(object target, string name)
    {
        return target.GetType().InvokeMember(name, BindingFlags.GetProperty, null, target, null);
    }

    private static object Method(object target, string name, params object[] arguments)
    {
        return target.GetType().InvokeMember(name, BindingFlags.InvokeMethod, null, target, arguments);
    }

    private static void Release(object value)
    {
        if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value);
    }

    private static bool SamePath(string left, string right)
    {
        if (String.IsNullOrEmpty(left)) return false;
        try {
            return String.Equals(Path.GetFullPath(left).TrimEnd('\\'), Path.GetFullPath(right).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
        } catch (ArgumentException) { return false;
        } catch (NotSupportedException) { return false; }
    }

    private static bool ActivateWindow(IntPtr window)
    {
        IntPtr root = GetAncestor(window, 2); // Explorer tabs may expose a child HWND.
        if (root != IntPtr.Zero) window = root;
        ShowWindowAsync(window, IsIconic(window) ? 9 : 5);
        // Raise a normal window for this request; never leave Explorer always on top.
        SetWindowPos(window, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040 | 0x4000);
        if (SetForegroundWindow(window) && GetForegroundWindow() == window) return true;

        uint process;
        uint current = GetCurrentThreadId();
        uint foreground = GetWindowThreadProcessId(GetForegroundWindow(), out process);
        uint target = GetWindowThreadProcessId(window, out process);
        bool joinedForeground = false;
        bool joinedTarget = false;
        try {
            // The API runs in a hidden service; share input only for this user-requested activation.
            if (foreground != 0 && foreground != current) joinedForeground = AttachThreadInput(current, foreground, true);
            if (target != 0 && target != current && target != foreground) joinedTarget = AttachThreadInput(current, target, true);
            BringWindowToTop(window);
            SetForegroundWindow(window);
        } finally {
            if (joinedTarget) AttachThreadInput(current, target, false);
            if (joinedForeground) AttachThreadInput(current, foreground, false);
        }
        return GetForegroundWindow() == window;
    }

    private static bool ActivateFolder(string directory, string selectedPath, bool waitForWindow)
    {
        object windows = null;
        try {
            // Enumerate existing windows directly; this COM collection cannot open another folder.
            windows = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("9BA05972-F6A8-11CF-A442-00A0C90A8F39")));
            DateTime deadline = DateTime.UtcNow.AddSeconds(3);
            bool found = false;
            while (DateTime.UtcNow < deadline) {
                int count = Convert.ToInt32(Property(windows, "Count"));
                for (int index = 0; index < count; index++) {
                    object window = null, view = null, folder = null, self = null, item = null;
                    try {
                        window = Method(windows, "Item", index);
                        view = Property(window, "Document");
                        folder = Property(view, "Folder");
                        self = Property(folder, "Self");
                        if (!SamePath(Convert.ToString(Property(self, "Path")), directory)) continue;
                        found = true;
                        if (selectedPath != null) {
                            item = Method(folder, "ParseName", Path.GetFileName(selectedPath));
                            if (item == null) continue;
                            // Select, clear any other selection, scroll into view, and focus the exact file.
                            Method(view, "SelectItem", item, 1 | 4 | 8 | 16);
                        }
                        IntPtr handle = new IntPtr(Convert.ToInt64(Property(window, "HWND")));
                        if (ActivateWindow(handle)) return true;
                    } catch (COMException) { // An Explorer tab may still be navigating.
                    } catch (TargetInvocationException) {
                    } finally {
                        Release(item); Release(self); Release(folder); Release(view); Release(window);
                    }
                }
                // A failure to activate an existing window must never open a second window.
                if (!found && !waitForWindow) return false;
                Thread.Sleep(75);
            }
            if (!found) return false;
            throw new IOException("Windows could not bring the requested download folder to the foreground. Please try again.");
        } finally { Release(windows); }
    }
}
