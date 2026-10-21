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
    public sealed class PowerShellPowerService : IPowerService
    {
        private readonly string root;
        private readonly object gate=new object();
        private int active;
        private bool disposed;
        private TransparencyReview review;
        private bool answered,accepted;
        public PowerShellPowerService(string repositoryRoot){root=Path.GetFullPath(repositoryRoot);}
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
        public Task<PowerResult> ExecuteAsync(PowerAction action,bool confirmed)
        {return ExecuteAsync(action,confirmed,null,false);}
        public Task<PowerResult> ExecuteAsync(PowerAction action,bool confirmed,string targetGuid,bool allowCreate)
        {
            lock(gate){
                if(disposed||!Enum.IsDefined(typeof(PowerAction),action))return Task.FromResult(PowerResult.Failure("Solicitud no disponible."));
                if(action!=PowerAction.Read&&!confirmed)return Task.FromResult(new PowerResult{Outcome="Cancelled",Message="Solicitud sin confirmación. No se escribió."});
                if(Interlocked.CompareExchange(ref active,1,0)!=0)return Task.FromResult(new PowerResult{Outcome="Busy",Message="Otra operación está en curso."});
            }
            return Task.Run(()=>{
                try{return Execute(action,confirmed,targetGuid,allowCreate);}
                catch(Exception){return PowerResult.Failure("El adaptador no pudo completar la operación. Resultado desconocido; vuelve a consultar y conserva los respaldos.");}
                finally{Interlocked.Exchange(ref active,0);}
            });
        }
        private PowerResult Execute(PowerAction action,bool confirmed,string targetGuid,bool allowCreate)
        {
            using(Runspace runspace=RunspaceFactory.CreateRunspace())
            using(PowerShell pipeline=PowerShell.Create()){
                // Enter, Assert, operaciones y Exit se ejecutan en la misma invocación/hilo.
                runspace.ThreadOptions=PSThreadOptions.ReuseThread;runspace.ApartmentState=ApartmentState.STA;
                runspace.Open();pipeline.Runspace=runspace;
                pipeline.AddScript(@"
param($root,$action,$confirmed,$review,$target,$create)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $root 'BackupStore.ps1')
. (Join-Path $root 'UiSupport.ps1')
. (Join-Path $root 'RecoveryOperations.ps1')
. (Join-Path $root 'PowerOperations.ps1')
. (Join-Path $root 'PowerAdapter.ps1')
$script:AppFolder=Join-Path $env:LOCALAPPDATA 'WinRendimiento'
$script:JunoPowerReview=$review
function Confirm-JunoReview([string]$message) {
    if(-not $script:JunoPowerReview.RequestReview($message)){
        throw [OperationCanceledException]::new('Revisión cancelada. Se conservan los respaldos.')
    }
}
Invoke-JunoPowerRequest $action -Confirmed:$confirmed -TargetGuid $target -AllowCreate:$create | ConvertTo-Json -Depth 8 -Compress
").AddArgument(root).AddArgument(action.ToString()).AddArgument(confirmed).AddArgument(this).AddArgument(targetGuid).AddArgument(allowCreate);
                var values=pipeline.Invoke();
                if(pipeline.HadErrors||values.Count!=1)throw new InvalidDataException("Contrato de adaptación inválido.");
                string json=values[0].ToString();
                if(json.Length>32768)throw new InvalidDataException("Respuesta excesiva.");
                PowerResult result=new JavaScriptSerializer{MaxJsonLength=32768,RecursionLimit=8}.Deserialize<PowerResult>(json);
                if(result==null||result.Plans==null||result.Plans.Length>256||result.Choices==null||result.Choices.Length>256||Array.IndexOf(new[]{"Unknown","Available","Missing","Unsupported","ChoiceRequired"},result.Availability)<0)throw new InvalidDataException("Estado inválido.");
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
