using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;

namespace Juno.Preview
{
    public interface IWindowsReadApi {Dictionary<string,string> Read(string key);}
    public static class DashboardCollector
    {
        public static DashboardReading Read(string key,IWindowsReadApi api)
        {
            if(!DashboardWire.IsKey(key))throw new ArgumentException("Lectura desconocida");
            try{return new DashboardReading{Key=key,Fields=api.Read(key)??new Dictionary<string,string>()};}
            catch(Exception){return new DashboardReading{Key=key,Failure="Consulta de Windows no disponible"};}
        }
    }
    // Solo GET/SELECT y APIs de lectura. No utiliza metodos WMI, Registry ni powercfg.
    public sealed class WindowsReadApi : IWindowsReadApi
    {
        [StructLayout(LayoutKind.Sequential)] private struct MemoryStatus
        {public uint Length,Load;public ulong TotalPhys,AvailPhys,TotalPage,AvailPage,TotalVirtual,AvailVirtual,Extended;}
        [DllImport("kernel32.dll",SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)] private static extern bool GlobalMemoryStatusEx(ref MemoryStatus value);
        [DllImport("kernel32.dll",SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)] private static extern bool GetPhysicallyInstalledSystemMemory(out ulong kilobytes);
        [DllImport("powrprof.dll")] private static extern uint PowerGetActiveScheme(IntPtr root,out IntPtr scheme);
        [DllImport("powrprof.dll")] private static extern uint PowerReadFriendlyName(IntPtr root,IntPtr scheme,IntPtr subgroup,IntPtr setting,IntPtr buffer,ref uint size);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr value);
        private static string Invariant(object value){return value==null?null:Convert.ToString(value,CultureInfo.InvariantCulture);}
        private static ManagementObjectCollection Query(string wql,ManagementObjectSearcher searcher)
        {searcher.Query=new ObjectQuery(wql);searcher.Options=new EnumerationOptions{Timeout=TimeSpan.FromSeconds(3),ReturnImmediately=true,Rewindable=false};return searcher.Get();}
        public Dictionary<string,string> Read(string key)
        {
            Dictionary<string,string> data=new Dictionary<string,string>();
            switch(key){
                case "os":
                    using(ManagementObjectSearcher searcher=new ManagementObjectSearcher())
                    using(ManagementObjectCollection rows=Query("SELECT Caption,Version,BuildNumber,OSArchitecture FROM Win32_OperatingSystem",searcher))
                    {foreach(ManagementObject row in rows){using(row){data["Caption"]=Invariant(row["Caption"]);data["Version"]=Invariant(row["Version"]);data["Build"]=Invariant(row["BuildNumber"]);data["Architecture"]=Invariant(row["OSArchitecture"]);}break;}}break;
                case "cpu":
                    List<string> names=new List<string>();ulong cores=0,logical=0;bool coresKnown=true,logicalKnown=true;int count=0;
                    using(ManagementObjectSearcher searcher=new ManagementObjectSearcher())
                    using(ManagementObjectCollection rows=Query("SELECT Name,NumberOfCores,NumberOfLogicalProcessors FROM Win32_Processor",searcher))
                    {foreach(ManagementObject row in rows){using(row){count++;string name=Invariant(row["Name"]);if(!String.IsNullOrWhiteSpace(name)&&!names.Contains(name.Trim()))names.Add(name.Trim());ulong? c=DashboardNumbers.Parse(Invariant(row["NumberOfCores"])),l=DashboardNumbers.Parse(Invariant(row["NumberOfLogicalProcessors"]));if(!c.HasValue||c==0)coresKnown=false;else cores=checked(cores+c.Value);if(!l.HasValue||l==0)logicalKnown=false;else logical=checked(logical+l.Value);}}}
                    if(names.Count>0)data["Name"]=String.Join(" / ",names.ToArray());if(count>0&&coresKnown)data["Cores"]=Invariant(cores);if(count>0&&logicalKnown)data["Logical"]=Invariant(logical);break;
                case "ram":
                    ulong installed;if(GetPhysicallyInstalledSystemMemory(out installed)&&installed>0)data["Installed"]=Invariant(checked(installed*1024UL));
                    MemoryStatus memory=new MemoryStatus();memory.Length=(uint)Marshal.SizeOf(typeof(MemoryStatus));
                    if(GlobalMemoryStatusEx(ref memory)){if(memory.TotalPhys>0)data["Usable"]=Invariant(memory.TotalPhys);data["Available"]=Invariant(memory.AvailPhys);}break;
                case "disk":
                    string root=Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.Windows));
                    if(String.IsNullOrEmpty(root))break;
                    DriveInfo drive=new DriveInfo(root);data["Drive"]=drive.Name;
                    if(drive.IsReady){long total=drive.TotalSize,free=drive.TotalFreeSpace;if(total>0)data["Total"]=Invariant(total);if(free>=0)data["Available"]=Invariant(free);}break;
                case "power":
                    IntPtr scheme=IntPtr.Zero,buffer=IntPtr.Zero;
                    try{
                        if(PowerGetActiveScheme(IntPtr.Zero,out scheme)!=0||scheme==IntPtr.Zero)break;
                        uint size=0;uint error=PowerReadFriendlyName(IntPtr.Zero,scheme,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,ref size);
                        if((error!=0&&error!=234)||size<2||size>65536)break;
                        buffer=Marshal.AllocHGlobal((int)size);
                        if(PowerReadFriendlyName(IntPtr.Zero,scheme,IntPtr.Zero,IntPtr.Zero,buffer,ref size)==0)data["Name"]=Marshal.PtrToStringUni(buffer);
                    }finally{if(buffer!=IntPtr.Zero)Marshal.FreeHGlobal(buffer);if(scheme!=IntPtr.Zero)LocalFree(scheme);}break;
                default:throw new ArgumentException("Lectura desconocida");
            }
            return data;
        }
    }
}
