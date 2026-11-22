param([string]$Root = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public static class LingoSaveIconVerification {
    delegate bool Enumerator(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumWindows(Enumerator callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr kind, IntPtr value, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern uint PrivateExtractIcons(string file, int index, int width, int height, IntPtr[] icons, uint[] ids, uint count, uint flags);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref Value value);
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
    struct ShellFileInfo {
        public IntPtr Icon; public int Index; public uint Attributes;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)] public string DisplayName;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=80)] public string TypeName;
    }
    [DllImport("shell32.dll",CharSet=CharSet.Unicode)]
    static extern IntPtr SHGetFileInfo(string path,uint attributes,ref ShellFileInfo info,uint size,uint flags);
    [StructLayout(LayoutKind.Sequential)] struct Key { public Guid Format; public uint Id; }
    [StructLayout(LayoutKind.Explicit,Size=24)] struct Value { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public IntPtr Pointer; }
    [ComImport,Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index,out Key key);
        [PreserveSig] int GetValue(ref Key key,out Value value);
        [PreserveSig] int SetValue(ref Key key,ref Value value);
        [PreserveSig] int Commit();
    }
    static string Read(IPropertyStore store,uint id) {
        Key key=new Key {Format=new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),Id=id};
        Value value;
        Marshal.ThrowExceptionForHR(store.GetValue(ref key,out value));
        try {return value.Type==31 ? Marshal.PtrToStringUni(value.Pointer) : null;}
        finally {PropVariantClear(ref value);}
    }
    static int SaveIcon(IntPtr handle,string output) {
        if(handle==IntPtr.Zero)return 0;
        using(Icon icon=Icon.FromHandle(handle))
        using(Bitmap bitmap=icon.ToBitmap()) {bitmap.Save(output,ImageFormat.Png);return bitmap.Width;}
    }
    public static Dictionary<string,object> Verify(string root) {
        var result=new Dictionary<string,object>();
        string directory=Path.Combine(root,"assets","icons");
        foreach(int size in new int[]{32,48,64,256}) {
            IntPtr[] handles=new IntPtr[1];uint[] ids=new uint[1];
            if(PrivateExtractIcons(Path.Combine(root,"LingoSave.exe"),0,size,size,handles,ids,1,0)!=1 || handles[0]==IntPtr.Zero)throw new Exception("EXE icon extraction failed");
            try {result["Embedded"+size]=SaveIcon(handles[0],Path.Combine(directory,"lingosave-exe-"+size+"-preview.png"));}
            finally {DestroyIcon(handles[0]);}
        }
        ShellFileInfo shell=new ShellFileInfo();
        if(SHGetFileInfo(Path.Combine(root,"LingoSave.exe"),0,ref shell,(uint)Marshal.SizeOf(typeof(ShellFileInfo)),0x100)==IntPtr.Zero || shell.Icon==IntPtr.Zero)throw new Exception("Shell EXE icon extraction failed");
        try {
            int size=SaveIcon(shell.Icon,Path.Combine(directory,"lingosave-explorer-preview.png"));
            result["ExplorerIconSize"]=size;
            IntPtr[] native=new IntPtr[1];uint[] ids=new uint[1];
            if(PrivateExtractIcons(Path.Combine(root,"LingoSave.exe"),0,size,size,native,ids,1,0)!=1)throw new Exception("Comparison icon extraction failed");
            try {
                using(Icon shellIcon=Icon.FromHandle(shell.Icon))
                using(Icon embeddedIcon=Icon.FromHandle(native[0]))
                using(Bitmap actual=shellIcon.ToBitmap())
                using(Bitmap expected=embeddedIcon.ToBitmap()) {
                    for(int y=0;y<size;y++)for(int x=0;x<size;x++) {
                        Color a=actual.GetPixel(x,y),b=expected.GetPixel(x,y);
                        // Shell premultiplies translucent pixels; tolerate its
                        // one-level colour rounding while comparing coverage.
                        if(a.A!=b.A || Math.Abs(a.R*a.A/255-b.R*b.A/255)>2 ||
                            Math.Abs(a.G*a.A/255-b.G*b.A/255)>2 ||
                            Math.Abs(a.B*a.A/255-b.B*b.A/255)>2)
                            throw new Exception("Explorer still returns an old cached EXE icon");
                    }
                }
                result["ExplorerMatchesEmbedded"]=true;
            } finally {if(native[0]!=IntPtr.Zero)DestroyIcon(native[0]);}
        } finally {DestroyIcon(shell.Icon);}
        EnumWindows(delegate(IntPtr window,IntPtr unused) {
            if(!IsWindowVisible(window))return true;
            StringBuilder title=new StringBuilder(512);GetWindowText(window,title,title.Capacity);
            if(!title.ToString().StartsWith("LingoSave",StringComparison.OrdinalIgnoreCase))return true;
            Guid iid=typeof(IPropertyStore).GUID;IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(window,ref iid,out store));
            try {
                string appId=Read(store,5);if(appId!="LingoSave.Desktop")return true;
                result["WindowTitle"]=title.ToString();result["AppId"]=appId;
                result["RelaunchIcon"]=Read(store,3);result["RelaunchCommand"]=Read(store,2);
                uint dpi=GetDpiForWindow(window);result["Dpi"]=dpi;
                IntPtr small,large;
                SendMessageTimeout(window,0x7F,IntPtr.Zero,IntPtr.Zero,2,500,out small);
                SendMessageTimeout(window,0x7F,new IntPtr(1),IntPtr.Zero,2,500,out large);
                result["SmallIcon"]=SaveIcon(small,Path.Combine(directory,"lingosave-window-small-preview.png"));
                result["LargeIcon"]=SaveIcon(large,Path.Combine(directory,"lingosave-window-large-preview.png"));
                if((int)result["SmallIcon"]!=(int)Math.Round(16*dpi/96.0) || (int)result["LargeIcon"]!=(int)Math.Round(32*dpi/96.0))throw new Exception("Window icon does not match DPI");
                return false;
            } finally {Marshal.ReleaseComObject(store);}
        },IntPtr.Zero);
        if(!result.ContainsKey("AppId"))throw new Exception("No branded LingoSave window found");
        return result;
    }
}
'@

[LingoSaveIconVerification]::Verify([IO.Path]::GetFullPath($Root)) | ConvertTo-Json
