using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class LingoFolderPicker
{
    private const int Cancelled = unchecked((int)0x800704C7);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(string path, IntPtr binding, ref Guid iid, out IShellItem item);

    public static string Show(string currentPath, string title)
    {
        IntPtr previousDpi = IntPtr.Zero;
        try { previousDpi = SetThreadDpiAwarenessContext(new IntPtr(-4)); }
        catch (EntryPointNotFoundException) { }

        try
        {
            Rectangle screen = Screen.FromHandle(GetForegroundWindow()).WorkingArea;
            using (Form owner = new Form())
            {
                owner.ShowInTaskbar = false;
                owner.TopMost = true;
                owner.FormBorderStyle = FormBorderStyle.None;
                owner.StartPosition = FormStartPosition.Manual;
                owner.Bounds = new Rectangle(screen.Left + screen.Width / 2, screen.Top + screen.Height / 2, 1, 1);
                owner.Opacity = 0;
                owner.Show();
                owner.Activate();
                return Pick(owner.Handle, currentPath, title);
            }
        }
        finally
        {
            if (previousDpi != IntPtr.Zero) SetThreadDpiAwarenessContext(previousDpi);
        }
    }

    private static string Pick(IntPtr owner, string currentPath, string title)
    {
        IFileDialog dialog = (IFileDialog)new FileOpenDialog();
        IShellItem initial = null;
        IShellItem selected = null;
        try
        {
            uint options;
            dialog.GetOptions(out options);
            const uint PickFolders = 0x20, ForceFileSystem = 0x40, PathMustExist = 0x800;
            dialog.SetOptions(options | PickFolders | ForceFileSystem | PathMustExist);
            dialog.SetTitle(title);
            if (Directory.Exists(currentPath))
            {
                Guid itemId = typeof(IShellItem).GUID;
                SHCreateItemFromParsingName(currentPath, IntPtr.Zero, ref itemId, out initial);
                dialog.SetFolder(initial);
            }

            int hr = dialog.Show(owner);
            if (hr == Cancelled) return null;
            Marshal.ThrowExceptionForHR(hr);
            dialog.GetResult(out selected);
            IntPtr path;
            selected.GetDisplayName(0x80058000u, out path); // SIGDN_FILESYSPATH
            try { return Marshal.PtrToStringUni(path); }
            finally { Marshal.FreeCoTaskMem(path); }
        }
        finally
        {
            if (selected != null) Marshal.ReleaseComObject(selected);
            if (initial != null) Marshal.ReleaseComObject(initial);
            Marshal.ReleaseComObject(dialog);
        }
    }

    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    private class FileOpenDialog { }

    // Method order follows the native IFileDialog vtable through GetResult.
    [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileDialog
    {
        [PreserveSig] int Show(IntPtr owner);
        void SetFileTypes(uint count, IntPtr specs);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(uint options);
        void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem item);
        void SetFolder(IShellItem item);
        void GetFolder(out IShellItem item);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName(out IntPtr name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void GetResult(out IShellItem item);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint type, out IntPtr name);
    }
}
