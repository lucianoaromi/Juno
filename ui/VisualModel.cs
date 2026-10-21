using System;
using System.Threading.Tasks;
namespace Juno.Preview
{
    public interface IVisualSettingsLauncher { void Open(); }
    // Apertura independiente: reutiliza el resolvedor permitido, sin ejecutar un preset.
    public sealed class WindowsVisualSettingsLauncher : IVisualSettingsLauncher
    {
        private readonly string root;
        private readonly Action<string> launch;
        public WindowsVisualSettingsLauncher(string repositoryRoot):this(repositoryRoot,Start){}
        public WindowsVisualSettingsLauncher(string repositoryRoot,Action<string> start)
        {
            root=System.IO.Path.GetFullPath(repositoryRoot);
            if(start==null)throw new ArgumentNullException("start");launch=start;
        }
        public void Open()
        {
            string path;
            using(var runspace=System.Management.Automation.Runspaces.RunspaceFactory.CreateRunspace())
            using(var pipeline=System.Management.Automation.PowerShell.Create()){
                runspace.Open();pipeline.Runspace=runspace;
                pipeline.AddScript(@"
param($root)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $root 'UiSupport.ps1')
Get-JunoSystemTool 'SystemPropertiesPerformance.exe'
").AddArgument(root);
                var values=pipeline.Invoke();
                if(pipeline.HadErrors||values.Count!=1)throw new InvalidOperationException("Herramienta oficial de efectos visuales no disponible.");
                path=values[0].ToString();
                if(!System.IO.Path.IsPathRooted(path)||!String.Equals(System.IO.Path.GetFileName(path),"SystemPropertiesPerformance.exe",StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Ruta de herramienta oficial inválida.");
            }
            launch(path);
        }
        private static void Start(string path)
        {
            using(var process=System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path){UseShellExecute=false,WorkingDirectory=Environment.GetFolderPath(Environment.SpecialFolder.Windows)})){
                if(process==null)throw new InvalidOperationException("No se pudo iniciar la herramienta oficial.");
            }
            // Dispose libera el handle; no espera ni cierra la ventana de Windows.
        }
    }
    public enum VisualAction {Read,Quality,Maximum,Restore}
    public sealed class VisualResult
    {
        public string State {get;set;}
        public string Outcome {get;set;}
        public string Message {get;set;}
        public string Details {get;set;}
        public string BackupIssue {get;set;}
        public bool CanApply {get;set;}
        public bool CanRestore {get;set;}
        public bool Pending {get;set;}
        public bool PartialOperation {get;set;}
        public bool Historical {get;set;}
        public VisualResult(){State="Unknown";Outcome="Read";Message="Estado aún no consultado.";Details="";}
        public static VisualResult Failure(string text){return new VisualResult{Outcome="Failed",Message=text};}
    }
    public interface IVisualService : IDisposable
    {
        Task<VisualResult> ExecuteAsync(VisualAction action,bool confirmed);
        TransparencyReview PendingReview {get;}
    }
    public sealed class UnavailableVisualService : IVisualService
    {
        public TransparencyReview PendingReview {get{return null;}}
        public Task<VisualResult> ExecuteAsync(VisualAction action,bool confirmed){return Task.FromResult(VisualResult.Failure("Proveedor visual no configurado."));}
        public void Dispose(){}
    }
    public sealed class VisualController : IDisposable
    {
        private readonly IVisualService service;
        private Task<VisualResult> pending;
        private VisualAction action;
        private bool disposed,deciding;
        public VisualResult Snapshot {get;private set;}
        public bool HasRequested {get;private set;}
        public bool IsConfigured {get{return !(service is UnavailableVisualService);}}
        public bool IsBusy {get{return pending!=null;}}
        public bool IsWriting {get{return IsBusy&&action!=VisualAction.Read;}}
        public TransparencyReview PendingReview {get{return disposed?null:service.PendingReview;}}
        public VisualController(IVisualService source){if(source==null)throw new ArgumentNullException("source");service=source;Snapshot=new VisualResult();}
        public bool CanStart(VisualAction requested)
        {
            if(disposed||deciding||IsBusy||!Enum.IsDefined(typeof(VisualAction),requested))return false;
            return requested==VisualAction.Read||(requested==VisualAction.Restore?Snapshot.CanRestore:Snapshot.CanApply&&Snapshot.State!=requested.ToString());
        }
        public bool Start(VisualAction requested,ITransparencyConfirmation confirmation)
        {
            if(!CanStart(requested))return false;
            deciding=true;
            try{
                bool write=requested!=VisualAction.Read;
                string question=requested==VisualAction.Restore?"¿Querés restaurar la configuración visual anterior?":requested==VisualAction.Quality?"¿Querés aplicar Rendimiento + letras nítidas?\r\n\r\nSe mantiene el suavizado de fuentes.":"¿Querés aplicar Máximo rendimiento?\r\n\r\nDesactiva el suavizado de fuentes y puede reducir la legibilidad.";
                if(write&&(confirmation==null||!confirmation.Confirm("JUNO · Efectos visuales",question))){Snapshot.Message="Solicitud cancelada.";return false;}
                action=requested;HasRequested=true;
                try{pending=service.ExecuteAsync(requested,write);if(pending==null)throw new InvalidOperationException();}
                catch(Exception){pending=Task.FromResult(VisualResult.Failure("No se pudo iniciar la operación."));}
                return true;
            }finally{deciding=false;}
        }
        public bool Poll()
        {
            if(disposed||pending==null||!pending.IsCompleted)return false;
            try{Snapshot=pending.GetAwaiter().GetResult()??VisualResult.Failure("Respuesta vacía; vuelve a consultar.");}
            catch(Exception){Snapshot=VisualResult.Failure("Resultado desconocido. Vuelve a consultar y conserva los respaldos.");}
            finally{pending=null;}return true;
        }
        public static string StateText(string state)
        {switch(state){case "Default":return "Administrada por Windows";case "Custom":return "Personalizada";case "Quality":return "Rendimiento + letras nítidas";case "Maximum":return "Máximo rendimiento";case "Partial":return "Parcialmente reconocida";default:return "Estado desconocido";}}
        public string Status {get{
            if(IsBusy)return IsWriting?"Aplicando cambio…":"Consultando…";
            if(!String.IsNullOrEmpty(Snapshot.BackupIssue))return "El respaldo no es compatible. Revisá los detalles.";
            if(Snapshot.Outcome=="Conflict")return "La configuración cambió fuera de JUNO. Revisá los detalles.";
            if(Snapshot.Pending)return "Hay un cambio pendiente de revisión.";
            if(Snapshot.Outcome=="Failed")return "No se pudo completar el cambio. Revisá los detalles.";
            if(Snapshot.PartialOperation)return "El cambio anterior quedó incompleto. Revisá los detalles.";
            if(Snapshot.Outcome=="Busy")return "Otra operación está en curso. Volvé a consultar.";
            if(Snapshot.Outcome=="Cancelled"||Snapshot.Message=="Solicitud cancelada.")return "Solicitud cancelada.";
            if(Snapshot.Outcome=="Restored")return "Configuración anterior restaurada. Puede requerir cerrar sesión.";
            if(Snapshot.Outcome=="Applied")return "Configuración visual aplicada. Puede requerir cerrar sesión.";
            if(Snapshot.Historical)return "El respaldo anterior necesita una revisión.";
            if(Snapshot.State=="Quality"||Snapshot.State=="Maximum")return "Los efectos visuales ya están optimizados.";
            if(Snapshot.State=="Partial")return "Hay diferencias en la configuración. Revisá los detalles.";
            return "Reducí animaciones y efectos. El resultado depende de cada equipo.";
        }}
        public string Details {get{return "Estado: "+Snapshot.State+"\r\nResultado: "+Snapshot.Outcome+"\r\nRespaldo: "+Snapshot.BackupIssue+"\r\nPendiente: "+Snapshot.Pending+"\r\nHistórico: "+Snapshot.Historical+"\r\nRestauración disponible: "+Snapshot.CanRestore+"\r\n\r\n"+Snapshot.Message+"\r\n\r\n"+Snapshot.Details;}}
        public void Dispose(){if(disposed)return;disposed=true;if(pending!=null)pending.ContinueWith(t=>{if(t.IsFaulted){AggregateException observed=t.Exception;}},TaskScheduler.Default);service.Dispose();pending=null;}
    }
}
