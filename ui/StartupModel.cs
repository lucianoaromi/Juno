using System;
using System.Threading.Tasks;

namespace Juno.Preview
{
    public enum StartupAction { Read,Enable,Disable,Restore }
    public sealed class StartupEntry
    {
        public string Id {get;set;}
        public string Name {get;set;}
        public string State {get;set;}
        public string Scope {get;set;}
        public string Fingerprint {get;set;}
        public string ApprovalToken {get;set;}
        public string Reason {get;set;}
        public bool CanChange {get;set;}
        public bool NeedsReview {get;set;}
    }
    public sealed class StartupResult
    {
        public StartupEntry[] Entries {get;set;}
        public string Outcome {get;set;}
        public string Message {get;set;}
        public string Details {get;set;}
        public string BackupIssue {get;set;}
        public bool CanRestore {get;set;}
        public bool Pending {get;set;}
        public bool Historical {get;set;}
        public int Remaining {get;set;}
        public StartupResult(){Entries=new StartupEntry[0];Outcome="Read";Message="Consultá la lista para continuar.";Details="";}
        public static StartupResult Failure(string message){return new StartupResult{Outcome="Failed",Message=message};}
    }
    public interface IStartupService : IDisposable
    {
        Task<StartupResult> ExecuteAsync(StartupAction action,string id,string fingerprint,string approvalToken,bool confirmed);
        TransparencyReview PendingReview {get;}
    }
    public sealed class UnavailableStartupService : IStartupService
    {
        public TransparencyReview PendingReview {get{return null;}}
        public Task<StartupResult> ExecuteAsync(StartupAction action,string id,string fingerprint,string approvalToken,bool confirmed){return Task.FromResult(StartupResult.Failure("Proveedor de inicio no configurado."));}
        public void Dispose(){}
    }
    public interface IStartupSettingsLauncher {void Open();}
    public sealed class WindowsStartupSettingsLauncher : IStartupSettingsLauncher
    {
        public const string SettingsUri="ms-settings:startupapps";
        private readonly Action<string> launch;
        public WindowsStartupSettingsLauncher():this(Start){}
        public WindowsStartupSettingsLauncher(Action<string> start){if(start==null)throw new ArgumentNullException("start");launch=start;}
        public void Open(){launch(SettingsUri);}
        private static void Start(string uri)
        {
            using(var process=System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(uri){UseShellExecute=true})){}
        }
    }
    public sealed class StartupController : IDisposable
    {
        private readonly IStartupService service;
        private Task<StartupResult> pending;
        private StartupAction action;
        private bool disposed,deciding;
        public StartupResult Snapshot {get;private set;}
        public bool HasRequested {get;private set;}
        public bool IsConfigured {get{return !(service is UnavailableStartupService);}}
        public bool IsBusy {get{return pending!=null;}}
        public bool IsWriting {get{return IsBusy&&action!=StartupAction.Read;}}
        public TransparencyReview PendingReview {get{return disposed?null:service.PendingReview;}}
        public StartupController(IStartupService source){if(source==null)throw new ArgumentNullException("source");service=source;Snapshot=new StartupResult();}
        public StartupEntry Find(string id)
        {
            StartupEntry result=null;
            foreach(var entry in Snapshot.Entries){if(String.Equals(entry.Id,id,StringComparison.Ordinal)){if(result!=null)return null;result=entry;}}
            return result;
        }
        public bool CanStart(StartupAction requested,string id)
        {
            if(disposed||deciding||IsBusy||!Enum.IsDefined(typeof(StartupAction),requested))return false;
            if(requested==StartupAction.Read)return true;
            if(!String.IsNullOrEmpty(Snapshot.BackupIssue))return false;
            if(requested==StartupAction.Restore)return Snapshot.CanRestore;
            var entry=Find(id);
            return entry!=null&&entry.CanChange&&((requested==StartupAction.Enable&&entry.State=="Disabled")||(requested==StartupAction.Disable&&entry.State=="Enabled"));
        }
        public bool Start(StartupAction requested,string id,ITransparencyConfirmation confirmation)
        {
            if(!CanStart(requested,id))return false;
            deciding=true;
            try{
                var entry=requested==StartupAction.Enable||requested==StartupAction.Disable?Find(id):null;
                bool write=requested!=StartupAction.Read;
                string question=requested==StartupAction.Restore?"¿Restaurar los estados de inicio guardados por JUNO?":"¿"+(requested==StartupAction.Enable?"Activar ":"Desactivar ")+(entry==null?"":entry.Name)+" al iniciar Windows?";
                if(entry!=null&&entry.NeedsReview)question+="\r\n\r\n"+entry.Reason;
                if(write&&(confirmation==null||!confirmation.Confirm("JUNO · Programas de inicio",question))){Snapshot.Message="Solicitud cancelada.";return false;}
                action=requested;HasRequested=true;
                try{pending=service.ExecuteAsync(requested,entry==null?"":entry.Id,entry==null?"":entry.Fingerprint,entry==null?"":entry.ApprovalToken,write);if(pending==null)throw new InvalidOperationException();}
                catch(Exception error){pending=Task.FromResult(new StartupResult{Outcome="Failed",Message="No se pudo iniciar la operación. Actualizá la lista.",Details=error.ToString()});}
                return true;
            }finally{deciding=false;}
        }
        public bool Poll()
        {
            if(disposed||pending==null||!pending.IsCompleted)return false;
            try{Snapshot=pending.GetAwaiter().GetResult()??StartupResult.Failure("Respuesta vacía. Actualizá la lista.");}
            catch(Exception error){Snapshot=new StartupResult{Outcome="Failed",Message="Resultado desconocido. Consultá el estado y conservá los respaldos.",Details=error.ToString()};}
            finally{pending=null;}return true;
        }
        public string Status {get{return IsBusy?(IsWriting?"Aplicando cambio…":"Consultando programas…"):Snapshot.Message;}}
        public void Dispose(){if(disposed)return;disposed=true;if(pending!=null)pending.ContinueWith(t=>{if(t.IsFaulted){AggregateException observed=t.Exception;}},TaskScheduler.Default);service.Dispose();pending=null;}
    }
}
