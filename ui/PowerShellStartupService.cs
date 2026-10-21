using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace Juno.Preview
{
    public sealed class PowerShellStartupService : IStartupService
    {
        private readonly string root;
        private readonly object gate=new object();
        private bool disposed,active,answered,accepted;
        private TransparencyReview review;
        public PowerShellStartupService(string repositoryRoot){root=Path.GetFullPath(repositoryRoot);}
        public TransparencyReview PendingReview {get{lock(gate){return review;}}}
        public bool RequestReview(string message)
        {
            lock(gate){
                if(disposed)return false;answered=false;accepted=false;
                TransparencyReview current=null;current=new TransparencyReview(message,allowed=>AnswerReview(current,allowed));review=current;
                while(!answered&&!disposed)Monitor.Wait(gate);
                review=null;return answered&&accepted;
            }
        }
        private void AnswerReview(TransparencyReview request,bool allowed)
        {lock(gate){if(!Object.ReferenceEquals(review,request)||answered)return;accepted=allowed;answered=true;review=null;Monitor.PulseAll(gate);}}
        public Task<StartupResult> ExecuteAsync(StartupAction action,string id,string fingerprint,string approvalToken,bool confirmed)
        {
            lock(gate){
                if(disposed||!Enum.IsDefined(typeof(StartupAction),action))return Task.FromResult(StartupResult.Failure("Solicitud no disponible."));
                if(action!=StartupAction.Read&&!confirmed)return Task.FromResult(new StartupResult{Outcome="Cancelled",Message="Solicitud cancelada."});
                if(active)return Task.FromResult(new StartupResult{Outcome="Busy",Message="Otra operación está en curso."});
                active=true;
            }
            return Task.Run(()=>{
                try{return Execute(action,id,fingerprint,approvalToken,confirmed);}
                catch(Exception error){return new StartupResult{Outcome="Failed",Message="Resultado desconocido. Consultá el estado y conservá los respaldos.",Details=error.ToString()};}
                finally{lock(gate){active=false;}}
            });
        }
        private StartupResult Execute(StartupAction action,string id,string fingerprint,string approvalToken,bool confirmed)
        {
            using(var runspace=RunspaceFactory.CreateRunspace())using(var pipeline=PowerShell.Create()){
                runspace.ThreadOptions=PSThreadOptions.ReuseThread;runspace.ApartmentState=ApartmentState.STA;runspace.Open();pipeline.Runspace=runspace;
                pipeline.AddScript(@"
param($root,$action,$id,$fingerprint,$approvalToken,$confirmed,$review)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $root 'BackupStore.ps1')
$script:AppFolder=Join-Path $env:LOCALAPPDATA 'WinRendimiento'
. (Join-Path $root 'StartupOperations.ps1')
. (Join-Path $root 'StartupAdapter.ps1')
$script:JunoStartupReview=$review
function Confirm-JunoReview([string]$message) {
    if(-not $script:JunoStartupReview.RequestReview($message)){throw [OperationCanceledException]::new('Revisión cancelada.')}
}
Invoke-JunoStartupRequest $action -Id $id -Fingerprint $fingerprint -ApprovalToken $approvalToken -Confirmed:$confirmed | ConvertTo-Json -Depth 16 -Compress
").AddArgument(root).AddArgument(action.ToString()).AddArgument(id).AddArgument(fingerprint).AddArgument(approvalToken).AddArgument(confirmed).AddArgument(this);
                var values=pipeline.Invoke();
                if(pipeline.HadErrors||values.Count!=1)throw new InvalidDataException("Contrato de adaptación inválido.");
                string json=values[0].ToString();if(json.Length>4194304)throw new InvalidDataException("Respuesta excesiva.");
                var result=new JavaScriptSerializer{MaxJsonLength=4194304,RecursionLimit=24}.Deserialize<StartupResult>(json);
                if(result==null||result.Entries==null||result.Entries.Length>4096)throw new InvalidDataException("Inventario inválido.");
                foreach(var entry in result.Entries)if(entry==null||String.IsNullOrEmpty(entry.Id)||entry.Id.Length>16383||Array.IndexOf(new[]{"Enabled","Disabled","Unknown"},entry.State)<0)throw new InvalidDataException("Entrada inválida.");
                return result;
            }
        }
        public void Dispose(){lock(gate){disposed=true;Monitor.PulseAll(gate);}}
        // La escritura conserva su hilo y mutex hasta terminar; no Stop, Kill ni cambio de identidad.
    }
}
