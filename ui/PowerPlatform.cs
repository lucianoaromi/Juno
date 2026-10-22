using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace Juno.Preview
{
    // SYSTEM_POWER_CAPABILITIES de WinSDK para Windows 10/11 (sin punteros).
    public static class PowerPlatform
    {
        [StructLayout(LayoutKind.Explicit, Size=76)]
        private struct Capabilities { [FieldOffset(20)] public byte AoAc; }
        [DllImport("powrprof.dll",SetLastError=true)]
        [return: MarshalAs(UnmanagedType.U1)]
        private static extern bool GetPwrCapabilities(out Capabilities capabilities);
        public static bool ModernStandby()
        {
            Capabilities value;
            if(!GetPwrCapabilities(out value))throw new Win32Exception(Marshal.GetLastWin32Error());
            return value.AoAc!=0;
        }
    }
    public interface IPowerPlansLauncher { void Open(); }
    public sealed class WindowsPowerPlansLauncher : IPowerPlansLauncher
    {
        private readonly Action<ProcessStartInfo> launch;
        public WindowsPowerPlansLauncher():this(Start){}
        public WindowsPowerPlansLauncher(Action<ProcessStartInfo> start)
        {if(start==null)throw new ArgumentNullException("start");launch=start;}
        public void Open()
        {
            string system=Environment.GetFolderPath(Environment.SpecialFolder.System);
            if(Environment.Is64BitOperatingSystem&&!Environment.Is64BitProcess)
                system=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"Sysnative");
            launch(new ProcessStartInfo(Path.Combine(system,"control.exe"),"/name Microsoft.PowerOptions"){UseShellExecute=true});
        }
        private static void Start(ProcessStartInfo info)
        {using(var process=Process.Start(info)){}}
    }
    public interface IColorsSettingsLauncher { void Open(); }
    public interface ICleanupSettingsLauncher { void Open(); }
    public sealed class WindowsCleanupSettingsLauncher : ICleanupSettingsLauncher
    {
        private readonly Action<ProcessStartInfo> launch;
        public WindowsCleanupSettingsLauncher():this(Start){}
        public WindowsCleanupSettingsLauncher(Action<ProcessStartInfo> start)
        {if(start==null)throw new ArgumentNullException("start");launch=start;}
        public void Open(){launch(new ProcessStartInfo("ms-settings:storagesense"){UseShellExecute=true});}
        private static void Start(ProcessStartInfo info)
        {using(var process=Process.Start(info)){}}
    }
    public sealed class WindowsColorsSettingsLauncher : IColorsSettingsLauncher
    {
        private readonly Action<ProcessStartInfo> launch;
        public WindowsColorsSettingsLauncher():this(Start){}
        public WindowsColorsSettingsLauncher(Action<ProcessStartInfo> start)
        {if(start==null)throw new ArgumentNullException("start");launch=start;}
        public void Open(){launch(new ProcessStartInfo("ms-settings:colors"){UseShellExecute=true});}
        // ShellExecute puede reutilizar una ventana existente sin devolver un proceso.
        private static void Start(ProcessStartInfo info)
        {using(var process=Process.Start(info)){}}
    }
}
