using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;

namespace LingoSaveDesktop
{
    // The UI runs in a browser process. Give that window our own taskbar identity
    // and native icons instead of letting the browser enlarge its small favicon.
    internal sealed class DesktopBranding : IDisposable
    {
        internal const string AppId = "LingoSave.Desktop";
        private readonly string iconPath;
        private readonly Dictionary<int, IntPtr> icons = new Dictionary<int, IntPtr>();
        private IntPtr window;
        private IntPtr originalSmall;
        private IntPtr originalLarge;
        private static readonly Guid PropertyFormat = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
        [DllImport("shell32.dll")]
        private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int width, int height, uint flags);
        [DllImport("user32.dll")]
        private static extern bool DestroyIcon(IntPtr icon);
        [DllImport("user32.dll")]
        private static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll")]
        private static extern uint GetDpiForWindow(IntPtr hwnd);
        [DllImport("user32.dll")]
        private static extern uint GetDpiForSystem();

        [StructLayout(LayoutKind.Sequential)]
        private struct PropertyKey
        {
            public Guid Format;
            public uint Id;
            public PropertyKey(uint id) { Format = PropertyFormat; Id = id; }
        }

        // The launcher is compiled for x64; a native PROPVARIANT is 24 bytes.
        [StructLayout(LayoutKind.Explicit, Size = 24)]
        private struct PropertyValue
        {
            [FieldOffset(0)] public ushort Type;
            [FieldOffset(8)] public IntPtr Pointer;
        }

        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int GetAt(uint index, out PropertyKey key);
            [PreserveSig] int GetValue(ref PropertyKey key, out PropertyValue value);
            [PreserveSig] int SetValue(ref PropertyKey key, ref PropertyValue value);
            [PreserveSig] int Commit();
        }

        internal static void InitializeProcess()
        {
            SetCurrentProcessExplicitAppUserModelID(AppId);
        }

        internal DesktopBranding(string root)
        {
            // A new resource filename also avoids the browser's old icon cache.
            iconPath = Path.Combine(root, "assets", "icons", "lingosave-app-v2.ico");
            if (!File.Exists(iconPath)) iconPath = Path.Combine(root, "assets", "icons", "lingosave-app.ico");
        }

        internal Icon CreateTrayIcon()
        {
            uint dpi = 96;
            try { dpi = GetDpiForSystem(); } catch (EntryPointNotFoundException) { }
            int size = Math.Max(16, (int)Math.Round(16 * Math.Max(96, dpi) / 96.0));
            using (Icon borrowed = Icon.FromHandle(GetIcon(size))) return (Icon)borrowed.Clone();
        }

        private IntPtr GetIcon(int size)
        {
            IntPtr icon;
            if (icons.TryGetValue(size, out icon)) return icon;
            icon = LoadImage(IntPtr.Zero, iconPath, 1, size, size, 0x10);
            if (icon == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "无法加载 LingoSave 图标。");
            icons.Add(size, icon);
            return icon;
        }

        private static IntPtr ReadWindowIcon(IntPtr hwnd, int kind)
        {
            IntPtr result;
            return SendMessageTimeout(hwnd, 0x7F, new IntPtr(kind), IntPtr.Zero, 2, 150, out result) != IntPtr.Zero ? result : IntPtr.Zero;
        }

        private static void SetWindowIcon(IntPtr hwnd, int kind, IntPtr icon)
        {
            IntPtr unused;
            SendMessageTimeout(hwnd, 0x80, new IntPtr(kind), icon, 2, 150, out unused);
        }

        private static void SetProperty(IPropertyStore store, uint id, string text)
        {
            PropertyKey key = new PropertyKey(id);
            PropertyValue value = new PropertyValue();
            if (text != null) { value.Type = 31; value.Pointer = Marshal.StringToCoTaskMemUni(text); }
            try { Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value)); }
            finally { if (value.Pointer != IntPtr.Zero) Marshal.FreeCoTaskMem(value.Pointer); }
        }

        private void SetTaskbarProperties(IntPtr hwnd, bool clear)
        {
            Guid iid = typeof(IPropertyStore).GUID;
            IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(hwnd, ref iid, out store));
            try
            {
                SetProperty(store, 2, clear ? null : "\"" + System.Windows.Forms.Application.ExecutablePath + "\"");
                SetProperty(store, 3, clear ? null : iconPath + ",0");
                SetProperty(store, 4, clear ? null : "LingoSave");
                // Set the ID last: Windows refreshes the taskbar at this point.
                SetProperty(store, 5, clear ? null : AppId);
            }
            finally { Marshal.ReleaseComObject(store); }
        }

        internal void Apply(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) return;
            if (window != hwnd)
            {
                Detach();
                window = hwnd;
                originalSmall = ReadWindowIcon(hwnd, 0);
                originalLarge = ReadWindowIcon(hwnd, 1);
                SetTaskbarProperties(hwnd, false);
            }
            uint dpi = 96;
            try { dpi = GetDpiForWindow(hwnd); } catch (EntryPointNotFoundException) { }
            dpi = Math.Max(96, dpi);
            IntPtr small = GetIcon((int)Math.Round(16 * dpi / 96.0));
            IntPtr large = GetIcon((int)Math.Round(32 * dpi / 96.0));
            // Browser navigation can replace its window icon after initial load.
            if (ReadWindowIcon(hwnd, 0) != small) SetWindowIcon(hwnd, 0, small);
            if (ReadWindowIcon(hwnd, 1) != large) SetWindowIcon(hwnd, 1, large);
        }

        internal void Detach()
        {
            if (window != IntPtr.Zero && IsWindow(window))
            {
                try { SetTaskbarProperties(window, true); } catch (COMException) { }
                SetWindowIcon(window, 0, originalSmall);
                SetWindowIcon(window, 1, originalLarge);
            }
            window = IntPtr.Zero;
        }

        public void Dispose()
        {
            Detach();
            foreach (IntPtr icon in icons.Values) DestroyIcon(icon);
            icons.Clear();
        }
    }
}
