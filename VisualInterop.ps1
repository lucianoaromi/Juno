#requires -Version 5.1
# Declaración nativa única; se inicializa solo al solicitar una operación que la necesita.
function Initialize-JunoVisualInterop {
    if ('WinVisualEffects' -as [type]) { return }
$nativeCode = @'
using System;
using System.Runtime.InteropServices;
public static class WinVisualEffects {
    [StructLayout(LayoutKind.Sequential)]
    public struct ANIMATIONINFO {
        public uint cbSize;
        public int iMinAnimate;
    }
    [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SystemParametersInfoBool(uint action, uint param, out int value, uint update);
    // Los SPI_SET...BOOL reciben el valor BOOL en pvParam, NO un puntero.
    [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SystemParametersInfoSetBool(uint action, uint param, IntPtr value, uint update);
    [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SystemParametersInfoAnimation(uint action, uint param, ref ANIMATIONINFO value, uint update);
    // Avisar a las ventanas sobre un cambio visual sin reiniciar Explorer.
    [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, string lParam, uint flags, uint timeoutMs, out IntPtr result);
}
'@
Add-Type -TypeDefinition $nativeCode
}
