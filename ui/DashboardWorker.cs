using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Juno.Preview
{
    // Un trabajador privado por consulta. Los eventos de stdout nunca acceden a controles.
    public sealed class ProcessDashboardQuery : IDashboardQuery
    {
        private readonly string executable,script;
        private readonly int timeoutMilliseconds;
        private int active;
        private volatile bool blocked;
        public ProcessDashboardQuery(string powershell,string workerScript):this(powershell,workerScript,15000){}
        public ProcessDashboardQuery(string powershell,string workerScript,int timeout)
        {if(timeout<100||timeout>120000)throw new ArgumentOutOfRangeException("timeout");executable=powershell;script=workerScript;timeoutMilliseconds=timeout;}
        public bool IsActive {get{return Interlocked.CompareExchange(ref active,0,0)!=0;}}
        public Task<DashboardSnapshot> FetchAsync(CancellationToken cancellation)
        {
            if(blocked||Interlocked.CompareExchange(ref active,1,0)!=0)return Task.FromResult(new DashboardSnapshot{Failure="El trabajador anterior no ha terminado",CompletedUtc=DateTime.UtcNow});
            return Task.Run(()=>Collect(cancellation));
        }
        private DashboardSnapshot Collect(CancellationToken cancellation)
        {
            DashboardSnapshot snapshot=new DashboardSnapshot();object gate=new object();
            using(Process process=new Process())
            using(ManualResetEvent outputEnd=new ManualResetEvent(false))
            using(ManualResetEvent errorEnd=new ManualResetEvent(false))
            {
                bool started=false,exited=false,accepting=true;int invalidLines=0;
                DataReceivedEventHandler output=delegate(object sender,DataReceivedEventArgs e){
                    lock(gate){if(!accepting)return;if(e.Data==null){outputEnd.Set();return;}try{DashboardReading reading=DashboardWire.Decode(e.Data);if(snapshot.Readings.ContainsKey(reading.Key)){invalidLines++;return;}snapshot.Readings.Add(reading.Key,reading);}catch(Exception){invalidLines++;}}
                };
                DataReceivedEventHandler error=delegate(object sender,DataReceivedEventArgs e){lock(gate){if(accepting&&e.Data==null)errorEnd.Set();}};
                try{
                    cancellation.ThrowIfCancellationRequested();
                    if(!File.Exists(executable)||!File.Exists(script))throw new FileNotFoundException("Falta el trabajador");
                    if(script.Contains("\""))throw new ArgumentException("Ruta invalida");
                    process.StartInfo=new ProcessStartInfo{FileName=executable,Arguments="-NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -File \""+script+"\"",UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
                    process.StartInfo.StandardOutputEncoding=System.Text.Encoding.UTF8;
                    process.OutputDataReceived+=output;process.ErrorDataReceived+=error;
                    started=process.Start();if(!started)throw new InvalidOperationException("No se inicio el trabajador");
                    process.BeginOutputReadLine();process.BeginErrorReadLine();Stopwatch clock=Stopwatch.StartNew();
                    while(!(exited=process.WaitForExit(50))){if(cancellation.IsCancellationRequested)break;if(clock.ElapsedMilliseconds>=timeoutMilliseconds){snapshot.TimedOut=true;break;}}
                    if(!exited){process.Kill();exited=process.WaitForExit(1500);if(!exited){blocked=true;snapshot.Failure="El trabajador no pudo finalizar";}}
                    if(cancellation.IsCancellationRequested)snapshot.Failure="Consulta cancelada";
                    if(exited){outputEnd.WaitOne(1000);errorEnd.WaitOne(1000);if(process.ExitCode!=0&&!snapshot.TimedOut&&!cancellation.IsCancellationRequested)snapshot.Failure="La consulta no pudo completarse";}
                }catch(OperationCanceledException){snapshot.Failure="Consulta cancelada";}
                catch(Exception){snapshot.Failure="Consulta de Windows no disponible";}
                finally{
                    if(started&&!exited){try{if(!process.HasExited){process.Kill();exited=process.WaitForExit(1500);}else exited=true;}catch(Exception){blocked=true;}if(!exited)blocked=true;}
                    // Asegurar que ningún callback siga usando los handles al disponerlos.
                    lock(gate){accepting=false;}
                    process.OutputDataReceived-=output;process.ErrorDataReceived-=error;
                    if(started){try{process.CancelOutputRead();}catch(InvalidOperationException){}try{process.CancelErrorRead();}catch(InvalidOperationException){}}
                    Interlocked.Exchange(ref active,0);
                }
                lock(gate){if(invalidLines>0)snapshot.Failure="Respuesta parcial del trabajador";snapshot.CompletedUtc=DateTime.UtcNow;}
            }
            return snapshot;
        }
    }
}
