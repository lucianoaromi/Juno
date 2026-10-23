using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace Juno.Preview
{
    public sealed class PowerShellRecoveryService : IRecoveryService
    {
        private readonly string root;private readonly object gate=new object();private bool disposed,active;
        public PowerShellRecoveryService(string repositoryRoot){root=Path.GetFullPath(repositoryRoot);}
        public Task<RecoveryResult> ExecuteAsync(string id,string token,bool confirmed)
        {
            lock(gate){
                if(disposed||active)return Task.FromResult(new RecoveryResult{Outcome="Busy",Message="Otra operación está en curso."});
                if(!String.IsNullOrEmpty(id)&&(!confirmed||RecoveryPresentation.Name(id)==null))return Task.FromResult(new RecoveryResult{Outcome="Cancelled",Message="Restauración cancelada."});
                active=true;
            }
            return Task.Run(()=>{
                try{
                    lock(gate){if(disposed)return new RecoveryResult{Outcome="Cancelled",Message="Solicitud cancelada."};}
                    using(var runspace=RunspaceFactory.CreateRunspace())using(var pipeline=PowerShell.Create()){
                        runspace.ThreadOptions=PSThreadOptions.ReuseThread;runspace.ApartmentState=ApartmentState.STA;runspace.Open();pipeline.Runspace=runspace;
                        pipeline.AddScript(@"
param($root,$id,$token,$confirmed)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$script:AppFolder=Join-Path $env:LOCALAPPDATA 'WinRendimiento'
foreach($file in @('BackupStore.ps1','RecoveryOperations.ps1','UiSupport.ps1','PowerOperations.ps1','TransparencyOperations.ps1','StartupOperations.ps1','BackgroundInventory.ps1','PermisosUsuario.ps1','PermisosSegundoPlano.ps1','PowerAdapter.ps1','TransparencyAdapter.ps1','StartupAdapter.ps1','RecoveryAdapter.ps1')){. (Join-Path $root $file)}
function Confirm-JunoReview([string]$message){throw [OperationCanceledException]::new('Recuperación supervisada requerida. '+$message)}
$action=if($id){'Restore'}else{'Read'}
Invoke-JunoRecoveryRequest $action -Id $id -Token $token -Confirmed:$confirmed | ConvertTo-Json -Depth 16 -Compress
").AddArgument(root).AddArgument(id??"").AddArgument(token??"").AddArgument(confirmed);
                        var values=pipeline.Invoke();if(pipeline.HadErrors||values.Count!=1)throw new InvalidDataException("Contrato de recuperación inválido.");
                        string json=values[0].ToString();if(json.Length>4194304)throw new InvalidDataException("Respuesta excesiva.");
                        var result=new JavaScriptSerializer{MaxJsonLength=4194304,RecursionLimit=24}.Deserialize<RecoveryResult>(json);
                        if(result==null||result.Items==null||result.Items.Length>6)throw new InvalidDataException("Inventario de recuperación inválido.");
                        var seen=new System.Collections.Generic.HashSet<string>();
                        foreach(var item in result.Items){
                            if(item==null||RecoveryPresentation.Name(item.Id)==null||!seen.Add(item.Id)||Array.IndexOf(new[]{"Empty","Ready","Blocked","Conflict","Error"},item.State)<0||item.Count<0||item.Count>4096||
                                (item.CanRestore&&(item.State!="Ready"||item.Count==0||String.IsNullOrEmpty(item.Token)||item.Token.Length>128)))throw new InvalidDataException("Recuperación inválida.");
                        }
                        return result;
                    }
                }catch(Exception error){return new RecoveryResult{Outcome="Failed",Message="No se pudo comprobar el resultado. Conservá los respaldos y volvé a consultar.",Details=error.ToString(),Attempted=String.IsNullOrEmpty(id)?"":id};}
                finally{lock(gate){active=false;}}
            });
        }
        public void Dispose(){lock(gate){disposed=true;}}
    }
}
