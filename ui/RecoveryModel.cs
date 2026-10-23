using System;
using System.Threading.Tasks;

namespace Juno.Preview
{
    public sealed class RecoveryItem
    {
        public string Id {get;set;} public string State {get;set;} public string Token {get;set;}
        public string Message {get;set;} public string Details {get;set;}
        public bool CanRestore {get;set;} public int Count {get;set;}
        public RecoveryItem(){State="Empty";Token="";Message="";Details="";}
    }
    public sealed class RecoveryResult
    {
        public RecoveryItem[] Items {get;set;} public string Outcome {get;set;} public string Message {get;set;}
        public string Details {get;set;} public bool MachineChecked {get;set;} public string Attempted {get;set;}
        public RecoveryResult(){Items=new RecoveryItem[0];Outcome="Read";Message="";Details="";Attempted="";}
    }
    public interface IRecoveryService : IDisposable {Task<RecoveryResult> ExecuteAsync(string id,string token,bool confirmed);}
    public sealed class UnavailableRecoveryService : IRecoveryService
    {
        public Task<RecoveryResult> ExecuteAsync(string id,string token,bool confirmed){return Task.FromResult(new RecoveryResult{Outcome="Failed",Message="No se pudo consultar la recuperación."});}
        public void Dispose(){}
    }
    public static class RecoveryPresentation
    {
        public static string Name(string id)
        {
            switch(id){case "Power":return "Plan de energía";case "Transparency":return "Transparencia";case "Startup":return "Programas de inicio";
                case "BackgroundUser":return "Segundo plano · Esta cuenta";case "BackgroundPolicy":return "Segundo plano · Equipo";case "Trim":return "Configuración anterior de TRIM";default:return null;}
        }
        public static string Message(RecoveryItem item)
        {
            if(item.State=="Conflict")return "La configuración cambió fuera de JUNO. El respaldo se conserva.";
            if(item.State=="Error")return "No se pudo validar esta recuperación. El respaldo se conserva.";
            if(item.State=="Blocked")return "Requiere revisar permisos, compatibilidad o un respaldo antiguo.";
            if(item.Id=="Startup"||item.Id.StartsWith("Background",StringComparison.Ordinal))return "Cambios guardados: "+item.Count+" aplicación(es).";
            return "Configuración anterior guardada por JUNO.";
        }
    }
    public sealed class RecoveryController : IDisposable
    {
        private readonly IRecoveryService service;private Task<RecoveryResult> pending;private bool disposed,deciding,writing;
        public RecoveryResult Snapshot {get;private set;} public bool HasRequested {get;private set;}
        public bool IsBusy {get{return pending!=null||deciding;}} public bool IsWriting {get{return IsBusy&&writing;}}
        public bool IsConfigured {get{return !(service is UnavailableRecoveryService);}}
        public RecoveryController(IRecoveryService source){if(source==null)throw new ArgumentNullException("source");service=source;Snapshot=new RecoveryResult();}
        public RecoveryItem Find(string id){RecoveryItem match=null;foreach(var item in Snapshot.Items)if(item.Id==id){if(match!=null)return null;match=item;}return match;}
        public bool CanRestore(string id){var item=Find(id);return !disposed&&!IsBusy&&HasRequested&&item!=null&&item.CanRestore&&item.State=="Ready"&&!String.IsNullOrEmpty(item.Token);}
        public bool Start(string id,ITransparencyConfirmation confirmation)
        {
            if(disposed||IsBusy)return false;
            if(String.IsNullOrEmpty(id))id=null;
            if(id!=null&&!CanRestore(id))return false;
            var item=id==null?null:Find(id);string token=item==null?"":item.Token;
            deciding=true;
            try{
                if(id!=null){
                    string question="¿Restaurar "+RecoveryPresentation.Name(id)+" a la configuración guardada por JUNO?";
                    if(id=="Startup"||id.StartsWith("Background",StringComparison.Ordinal))question+="\r\n\r\nSe revisarán los cambios guardados para "+item.Count+" aplicación(es). Los conflictos conservarán su respaldo.";
                    if(id=="BackgroundPolicy")question+="\r\nAfecta a todas las cuentas del equipo.";
                    if(id=="Trim")question+="\r\n\r\nEsto desactiva TRIM NTFS en este equipo y puede afectar al mantenimiento de SSD. No se optimizarán discos.";
                    if(confirmation==null||!confirmation.Confirm("JUNO · Restaurar configuración",question)){Snapshot.Message="Restauración cancelada.";return false;}
                }
                HasRequested=true;writing=id!=null;
                try{pending=service.ExecuteAsync(id??"",token,writing);if(pending==null)throw new InvalidOperationException();}
                catch(Exception error){pending=Task.FromResult(new RecoveryResult{Outcome="Failed",Message="No se pudo iniciar la recuperación. Volvé a comprobar los respaldos.",Details=error.ToString()});}
                return true;
            }finally{deciding=false;}
        }
        public bool Poll()
        {
            if(disposed||pending==null||!pending.IsCompleted)return false;
            try{Snapshot=pending.GetAwaiter().GetResult()??new RecoveryResult{Outcome="Failed",Message="Resultado desconocido. Comprobá los respaldos."};}
            catch(Exception error){Snapshot=new RecoveryResult{Outcome="Failed",Message="Resultado desconocido. Comprobá el estado y conservá los respaldos.",Details=error.ToString()};}
            finally{pending=null;}return true;
        }
        public string Status
        {
            get{
                if(IsBusy)return writing?"Restaurando… Esperá la verificación.":"Comprobando respaldos…";
                if(!HasRequested)return "Comprobá si hay cambios anteriores para restaurar.";
                if(!String.IsNullOrEmpty(Snapshot.Message))return Snapshot.Message;
                bool visible=Array.Exists(Snapshot.Items,item=>item.State!="Empty");
                bool available=Array.Exists(Snapshot.Items,item=>item.State=="Ready"&&item.CanRestore);
                string message=visible?(available?"Elegí la configuración que querés recuperar.":"No hay recuperaciones disponibles por ahora. Los respaldos se conservan."):Snapshot.MachineChecked?"No hay cambios anteriores para restaurar.":"No hay cambios del usuario para restaurar.";
                if(!Snapshot.MachineChecked)message+=" Para comprobar los del equipo, abrí JUNO como administrador con la misma cuenta.";
                return message;
            }
        }
        public void Dispose(){if(disposed)return;disposed=true;if(pending!=null)pending.ContinueWith(t=>{if(t.IsFaulted){var observed=t.Exception;}},TaskScheduler.Default);service.Dispose();pending=null;}
    }
}
