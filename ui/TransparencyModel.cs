using System;
using System.Threading.Tasks;

namespace Juno.Preview
{
    public enum TransparencyAction { Read, Enable, Disable, Restore }
    public sealed class TransparencyResult
    {
        public string State {get;set;}
        public string Outcome {get;set;}
        public string Message {get;set;}
        public string BackupIssue {get;set;}
        public bool CanChange {get;set;}
        public bool CanRestore {get;set;}
        public bool Pending {get;set;}
        public bool Historical {get;set;}
        public TransparencyResult(){State="Unknown";Outcome="Read";Message="Estado aún no consultado.";}
        public static TransparencyResult Failure(string message)
        {return new TransparencyResult{State="Unavailable",Outcome="Failed",Message=message};}
    }
    // Una revisión pertenece a una sola operación; el hilo UI responde explícitamente.
    public sealed class TransparencyReview
    {
        private readonly Action<bool> answer;
        public string Message {get;private set;}
        public TransparencyReview(string message,Action<bool> response){Message=message;answer=response;}
        public void Answer(bool allowed){answer(allowed);}
    }
    public interface ITransparencyService : IDisposable
    {
        Task<TransparencyResult> ExecuteAsync(TransparencyAction action,bool confirmed);
        TransparencyReview PendingReview {get;}
    }
    public sealed class UnavailableTransparencyService : ITransparencyService
    {
        public TransparencyReview PendingReview {get{return null;}}
        public Task<TransparencyResult> ExecuteAsync(TransparencyAction action,bool confirmed)
        {return Task.FromResult(TransparencyResult.Failure("Proveedor de transparencia no configurado."));}
        public void Dispose(){}
    }
    public interface ITransparencyConfirmation
    {
        bool Confirm(string title,string message);
    }
    public sealed class TransparencyController : IDisposable
    {
        private readonly ITransparencyService service;
        private Task<TransparencyResult> pending;
        private TransparencyAction action;
        private bool disposed;
        public TransparencyResult Snapshot {get;private set;}
        public bool HasRequested {get;private set;}
        public bool IsBusy {get{return pending!=null;}}
        public bool IsWriting {get{return IsBusy&&action!=TransparencyAction.Read;}}
        public bool IsDisposed {get{return disposed;}}
        public TransparencyReview PendingReview {get{return disposed?null:service.PendingReview;}}
        public TransparencyController(ITransparencyService source)
        {if(source==null)throw new ArgumentNullException("source");service=source;Snapshot=new TransparencyResult();}
        public bool CanStart(TransparencyAction requested)
        {
            if(disposed||IsBusy||!Enum.IsDefined(typeof(TransparencyAction),requested))return false;
            return requested==TransparencyAction.Read||(requested==TransparencyAction.Restore?Snapshot.CanRestore:Snapshot.CanChange);
        }
        public bool Start(TransparencyAction requested,ITransparencyConfirmation confirmation)
        {
            if(!CanStart(requested))return false;
            bool write=requested!=TransparencyAction.Read;
            if(write){
                string verb=requested==TransparencyAction.Restore?"restaurar el original":requested==TransparencyAction.Enable?"activar la transparencia":"desactivar la transparencia";
                if(confirmation==null||!confirmation.Confirm("JUNO · Transparencia","¿Querés "+verb+"?\r\n\r\nEl efecto visual puede requerir cerrar sesión.")){
                    Snapshot.Message="Solicitud cancelada. No se inició ninguna escritura.";return false;
                }
            }
            action=requested;HasRequested=true;
            try{pending=service.ExecuteAsync(requested,write);if(pending==null)throw new InvalidOperationException();}
            catch(Exception){pending=Task.FromResult(TransparencyResult.Failure("No se pudo iniciar la operación."));}
            return true;
        }
        public bool Poll()
        {
            if(disposed||pending==null||!pending.IsCompleted)return false;
            try{Snapshot=pending.GetAwaiter().GetResult()??TransparencyResult.Failure("Respuesta vacía; resultado desconocido.");}
            catch(Exception){Snapshot=TransparencyResult.Failure("Operación fallida; resultado desconocido. Consultar y revisar el respaldo antes de reintentar.");}
            finally{pending=null;}
            return true;
        }
        public static string StateText(string state)
        {switch(state){case "Enabled":return "Activada";case "Disabled":return "Desactivada";case "Unavailable":return "No disponible";default:return "Estado desconocido";}}
        public string Status
        {
            get{
                if(IsBusy)return IsWriting?"Configuración solicitada · Operación en curso. Espera su verificación antes de cerrar.":"Consultando estado y respaldo… Puedes seguir navegando.";
                return (Snapshot.Pending?"Operación pendiente de reconciliación. ":"")+Snapshot.Message;
            }
        }
        public void Dispose()
        {
            if(disposed)return;disposed=true;
            // No se detiene ni se cancela una escritura. El proveedor libera su runspace al acabar.
            if(pending!=null){pending.ContinueWith(t=>{if(t.IsFaulted){AggregateException observed=t.Exception;}},TaskScheduler.Default);}
            service.Dispose();pending=null;
        }
    }
}
