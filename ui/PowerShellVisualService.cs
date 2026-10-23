using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace Juno.Preview
{
    // Puente aislado. No implementa decisiones de respaldo/restauración ni APIs de Windows.
    public sealed class PowerShellVisualService : IVisualService
    {
        private readonly string root;
        private readonly object gate=new object();
        private int active;
        private bool disposed;
        private TransparencyReview review;
        private bool answered,accepted;
        public PowerShellVisualService(string repositoryRoot){root=Path.GetFullPath(repositoryRoot);}
        public TransparencyReview PendingReview {get{lock(gate){return review;}}}
        public bool RequestReview(string message)
        {
            lock(gate){
                if(disposed)return false;
                answered=false;accepted=false;
                TransparencyReview current=null;
                current=new TransparencyReview(message,allowed=>AnswerReview(current,allowed));
                review=current;
                while(!answered&&!disposed)Monitor.Wait(gate);
                review=null;return answered&&accepted;
            }
        }
        private void AnswerReview(TransparencyReview request,bool allowed)
        {lock(gate){if(!Object.ReferenceEquals(review,request)||answered)return;accepted=allowed;answered=true;review=null;Monitor.PulseAll(gate);}}
        public Task<VisualResult> ExecuteAsync(VisualAction action,bool confirmed)
        {
            lock(gate){
                if(disposed||!Enum.IsDefined(typeof(VisualAction),action))return Task.FromResult(VisualResult.Failure("Solicitud no disponible."));
                if(action!=VisualAction.Read&&!confirmed)return Task.FromResult(new VisualResult{Outcome="Cancelled",Message="Solicitud sin confirmación. No se escribió."});
                if(action==VisualAction.Quality||action==VisualAction.Maximum)return Task.FromResult(VisualResult.Failure("Los perfiles visuales de JUNO están suspendidos. Configurá los efectos en Windows."));
                if(Interlocked.CompareExchange(ref active,1,0)!=0)return Task.FromResult(new VisualResult{Outcome="Busy",Message="Otra operación está en curso."});
            }
            return Task.Run(()=>{
                try{return Execute(action,confirmed);}
                catch(Exception){return VisualResult.Failure("El adaptador no pudo completar la operación. Resultado desconocido; vuelve a consultar y conserva los respaldos.");}
                finally{Interlocked.Exchange(ref active,0);}
            });
        }
        private VisualResult Execute(VisualAction action,bool confirmed)
        {
            using(Runspace runspace=RunspaceFactory.CreateRunspace())
            using(PowerShell pipeline=PowerShell.Create()){
                // Enter, Assert, operaciones y Exit se ejecutan en la misma invocación/hilo.
                runspace.ThreadOptions=PSThreadOptions.ReuseThread;runspace.ApartmentState=ApartmentState.STA;
                runspace.Open();pipeline.Runspace=runspace;
                pipeline.AddScript(@"
param($root,$action,$confirmed,$review)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $root 'BackupStore.ps1')
. (Join-Path $root 'RecoveryOperations.ps1')
. (Join-Path $root 'TransparencyOperations.ps1')
. (Join-Path $root 'VisualEffectsOperations.ps1')
. (Join-Path $root 'VisualAdapter.ps1')
$script:AppFolder=Join-Path $env:LOCALAPPDATA 'WinRendimiento'
$script:TransparencyKey='Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$script:JunoVisualReview=$review
function Confirm-JunoReview([string]$message) {
    if(-not $script:JunoVisualReview.RequestReview($message)){
        throw [OperationCanceledException]::new('Revisión cancelada. Se conservan los respaldos.')
    }
}
Invoke-JunoVisualRequest $action -Confirmed:$confirmed | ConvertTo-Json -Depth 8 -Compress
").AddArgument(root).AddArgument(action.ToString()).AddArgument(confirmed).AddArgument(this);
                var values=pipeline.Invoke();
                if(pipeline.HadErrors||values.Count!=1)throw new InvalidDataException("Contrato de adaptación inválido.");
                string json=values[0].ToString();
                if(json.Length>32768)throw new InvalidDataException("Respuesta excesiva.");
                VisualResult result=new JavaScriptSerializer{MaxJsonLength=32768,RecursionLimit=8}.Deserialize<VisualResult>(json);
                if(result==null||Array.IndexOf(new[]{"Default","Custom","Quality","Maximum","Partial","Unknown"},result.State)<0)throw new InvalidDataException("Estado inválido.");
                return result;
            }
        }
        public void Dispose()
        {
            lock(gate){disposed=true;Monitor.PulseAll(gate);}
            // Sin Stop/timeout/Kill. Una operación que ya escribe termina bajo su mutex.
        }
    }
}
