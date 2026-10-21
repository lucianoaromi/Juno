using System;
using System.Threading.Tasks;

namespace Juno.Preview
{
    public sealed class PowerPlanChoice
    {
        public string Guid {get;set;}
        public string Name {get;set;}
    }
    public interface IPowerPlanSelection { string Choose(PowerPlanChoice[] choices); }
    public enum PowerAction {Read,Apply,Restore}
    public sealed class PowerResult
    {
        public string ActiveGuid {get;set;}
        public string ActiveName {get;set;}
        public string Availability {get;set;}
        public bool HighAvailable {get;set;}
        public bool HighActive {get;set;}
        public bool Administrator {get;set;}
        public bool? ModernStandby {get;set;}
        public bool CanApply {get;set;}
        public bool CanRestore {get;set;}
        public bool Pending {get;set;}
        public bool Historical {get;set;}
        public string BackupIssue {get;set;}
        public string Outcome {get;set;}
        public string Message {get;set;}
        public string[] Plans {get;set;}
        public PowerPlanChoice[] Choices {get;set;}
        public bool RequiresSelection {get;set;}
        public bool RequiresCreation {get;set;}
        public bool SelectionActive {get;set;}
        public PowerResult(){ActiveName="Estado aún no consultado";Availability="Unknown";Outcome="Read";Message="Consulta el estado antes de solicitar cambios.";Plans=new string[0];Choices=new PowerPlanChoice[0];}
        public static PowerResult Failure(string message){return new PowerResult{Outcome="Failed",Message=message};}
    }
    public interface IPowerService : IDisposable
    {
        Task<PowerResult> ExecuteAsync(PowerAction action,bool confirmed);
        Task<PowerResult> ExecuteAsync(PowerAction action,bool confirmed,string targetGuid,bool allowCreate);
        TransparencyReview PendingReview {get;}
    }
    public sealed class UnavailablePowerService : IPowerService
    {
        public TransparencyReview PendingReview {get{return null;}}
        public Task<PowerResult> ExecuteAsync(PowerAction action,bool confirmed){return Task.FromResult(PowerResult.Failure("Proveedor de energía no configurado."));}
        public Task<PowerResult> ExecuteAsync(PowerAction action,bool confirmed,string targetGuid,bool allowCreate){return ExecuteAsync(action,confirmed);}
        public void Dispose(){}
    }
    public sealed class PowerController : IDisposable
    {
        private readonly IPowerService service;
        private Task<PowerResult> pending;
        private PowerAction action;
        private bool disposed;
        private bool deciding;
        private string selectedGuid,selectedName,requestedGuid,requestedName;
        public string RememberedGuid {get{return selectedGuid;}}
        public bool HasRememberedSelection {get{return CanReuseSelection();}}
        private bool CanReuseSelection()
        {
            return Snapshot.RequiresSelection&&Snapshot.CanApply&&SelectionIsValid();
        }
        private bool SelectionIsValid()
        {
            return selectedGuid!=null&&Snapshot.Administrator
                &&Snapshot.ModernStandby==false&&!Snapshot.Pending&&!Snapshot.Historical
                &&String.IsNullOrEmpty(Snapshot.BackupIssue)&&(Snapshot.Outcome=="Read"||Snapshot.Outcome=="Restored"||Snapshot.Outcome=="Applied")
                &&Array.Exists(Snapshot.Choices,p=>String.Equals(p.Guid,selectedGuid,StringComparison.OrdinalIgnoreCase)&&p.Name==selectedName);
        }
        public PowerResult Snapshot {get;private set;}
        public bool HasRequested {get;private set;}
        public bool IsConfigured {get{return !(service is UnavailablePowerService);}}
        public bool IsBusy {get{return pending!=null;}}
        public bool IsWriting {get{return IsBusy&&action!=PowerAction.Read;}}
        public TransparencyReview PendingReview {get{return disposed?null:service.PendingReview;}}
        public PowerController(IPowerService source){if(source==null)throw new ArgumentNullException("source");service=source;Snapshot=new PowerResult();}
        public bool CanStart(PowerAction requested)
        {
            if(disposed||deciding||IsBusy||!Enum.IsDefined(typeof(PowerAction),requested))return false;
            return requested==PowerAction.Read||(requested==PowerAction.Restore?Snapshot.CanRestore:Snapshot.CanApply);
        }
        public bool Start(PowerAction requested,ITransparencyConfirmation confirmation)
        {return Start(requested,confirmation,null);}
        public bool Start(PowerAction requested,ITransparencyConfirmation confirmation,IPowerPlanSelection selection)
        {
            if(!CanStart(requested))return false;
            string target=null;bool create=requested==PowerAction.Apply&&Snapshot.RequiresCreation;
            deciding=true;
            try{
                if(requested==PowerAction.Apply&&Snapshot.RequiresSelection){
                    target=CanReuseSelection()?selectedGuid:selection==null?null:selection.Choose(Snapshot.Choices);
                    if(String.IsNullOrWhiteSpace(target)){Snapshot.Message="Selección cancelada. No se inició ninguna escritura.";return false;}
                    Guid parsed;
                    if(!Guid.TryParse(target,out parsed)||!Array.Exists(Snapshot.Choices,p=>String.Equals(p.Guid,parsed.ToString(),StringComparison.OrdinalIgnoreCase))){Snapshot.Message="Selección inválida. Vuelve a consultar.";return false;}
                    target=parsed.ToString();create=false;
                }
            bool write=requested!=PowerAction.Read;
            string intent=requested==PowerAction.Restore?"¿Querés restaurar el plan anterior?":create?"¿Querés crear y activar Alto rendimiento?":target==null?"¿Querés activar Alto rendimiento?":"¿Querés activar el plan elegido: "+Array.Find(Snapshot.Choices,p=>String.Equals(p.Guid,target,StringComparison.OrdinalIgnoreCase)).Name+"?";
            if(write&&(confirmation==null||!confirmation.Confirm(requested==PowerAction.Restore?"JUNO · Restaurar plan anterior":create?"JUNO · Crear Alto rendimiento":"JUNO · Activar plan",
                intent+(requested==PowerAction.Restore?"":"\r\n\r\nPuede aumentar el consumo de batería.")))){Snapshot.Message="Solicitud cancelada. No se inició ninguna escritura.";return false;}
            requestedGuid=target;requestedName=target==null?null:Array.Find(Snapshot.Choices,p=>String.Equals(p.Guid,target,StringComparison.OrdinalIgnoreCase)).Name;
            action=requested;HasRequested=true;
            try{pending=service.ExecuteAsync(requested,write,target,create);if(pending==null)throw new InvalidOperationException();}
            catch(Exception){pending=Task.FromResult(PowerResult.Failure("No se pudo iniciar la operación."));}
            return true;
            }finally{deciding=false;}
        }
        public bool Poll()
        {
            if(disposed||pending==null||!pending.IsCompleted)return false;
            try{Snapshot=pending.GetAwaiter().GetResult()??PowerResult.Failure("Respuesta vacía; vuelve a consultar.");}
            catch(Exception){Snapshot=PowerResult.Failure("Consulta u operación fallida. Resultado desconocido; conserva los respaldos y vuelve a consultar.");}
            finally{pending=null;}
            // Solo recordar una selección explícita con resultado verificado. Nunca se persiste.
            if(action==PowerAction.Apply&&Snapshot.Outcome=="Applied"&&requestedGuid!=null
                &&String.Equals(Snapshot.ActiveGuid,requestedGuid,StringComparison.OrdinalIgnoreCase)&&!Snapshot.Pending&&String.IsNullOrEmpty(Snapshot.BackupIssue)){
                selectedGuid=requestedGuid;selectedName=requestedName;
            }
            else if(Snapshot.Outcome=="Failed"||Snapshot.Outcome=="Conflict"||Snapshot.Outcome=="Busy"||Snapshot.Pending||Snapshot.Historical||!String.IsNullOrEmpty(Snapshot.BackupIssue)
                ||!Snapshot.Administrator||Snapshot.ModernStandby!=false
                ||(Snapshot.RequiresSelection&&!SelectionIsValid())){selectedGuid=null;selectedName=null;}
            return true;
        }
        public string Status {get{return IsBusy?(IsWriting?"Operación de energía en curso. Espera su verificación antes de cerrar.":"Consultando energía y respaldo… Puedes seguir navegando."):(Snapshot.Pending?"Operación pendiente de reconciliación. ":"")+Snapshot.Message;}}
        public void Dispose()
        {
            if(disposed)return;disposed=true;
            if(pending!=null)pending.ContinueWith(t=>{if(t.IsFaulted){AggregateException observed=t.Exception;}},TaskScheduler.Default);
            service.Dispose();pending=null;
        }
    }
}
