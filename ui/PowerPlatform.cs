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
        public void Open()
        {
            string system=Environment.GetFolderPath(Environment.SpecialFolder.System);
            if(Environment.Is64BitOperatingSystem&&!Environment.Is64BitProcess)
                system=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"Sysnative");
            Process.Start(new ProcessStartInfo(Path.Combine(system,"control.exe"),"/name Microsoft.PowerOptions"){UseShellExecute=true});
        }
    }
}
