using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace Juno.Preview
{
    // Contrato de lectura; nunca contiene controles ni comandos de optimizacion.
    public sealed class DashboardReading
    {
        public string Key {get;set;}
        public Dictionary<string,string> Fields {get;set;}
        public string Failure {get;set;}
        public DashboardReading(){Fields=new Dictionary<string,string>();}
    }
    public sealed class DashboardSnapshot
    {
        public readonly Dictionary<string,DashboardReading> Readings=new Dictionary<string,DashboardReading>();
        public bool TimedOut;
        public string Failure;
        public DateTime? CompletedUtc;
    }
    public static class DashboardWire
    {
        public static readonly string[] Keys={"os","cpu","ram","disk","power"};
        public static bool IsKey(string key){return Array.IndexOf(Keys,key)>=0;}
        public static string Encode(DashboardReading value){return Serializer().Serialize(value);}
        private static JavaScriptSerializer Serializer(){return new JavaScriptSerializer{MaxJsonLength=16384,RecursionLimit=8};}
        public static DashboardReading Decode(string line)
        {
            if(String.IsNullOrWhiteSpace(line)||line.Length>16384)throw new FormatException("Respuesta invalida");
            DashboardReading result=Serializer().Deserialize<DashboardReading>(line);
            if(result==null||!IsKey(result.Key)||result.Fields==null||result.Fields.Count>16)throw new FormatException("Contrato invalido");
            foreach(KeyValuePair<string,string> item in result.Fields){if(item.Key.Length>64||(item.Value!=null&&item.Value.Length>1024))throw new FormatException("Campo excesivo");}
            if(result.Failure!=null&&result.Failure.Length>512)throw new FormatException("Error excesivo");
            return result;
        }
    }
    public interface IDashboardQuery
    {
        Task<DashboardSnapshot> FetchAsync(CancellationToken cancellation);
    }
    // Constructor de vista sin proveedor: útil para construir controles sin consultar Windows.
    public sealed class UnavailableDashboardQuery : IDashboardQuery
    {
        public Task<DashboardSnapshot> FetchAsync(CancellationToken cancellation)
        {return Task.FromResult(new DashboardSnapshot{CompletedUtc=DateTime.UtcNow,Failure="Proveedor no configurado"});}
    }
    public sealed class DashboardController : IDisposable
    {
        private readonly IDashboardQuery query;
        private CancellationTokenSource cancellation;
        private Task<DashboardSnapshot> pending;
        private bool disposed;
        public DashboardSnapshot Snapshot {get;private set;}
        public bool HasRequested {get;private set;}
        public bool IsBusy {get{return pending!=null;}}
        public bool IsDisposed {get{return disposed;}}
        public DashboardController(IDashboardQuery source)
        {if(source==null)throw new ArgumentNullException("source");query=source;Snapshot=new DashboardSnapshot();}
        public bool Refresh()
        {
            if(disposed||IsBusy)return false;
            HasRequested=true;cancellation=new CancellationTokenSource();
            try{pending=query.FetchAsync(cancellation.Token);if(pending==null)throw new InvalidOperationException("Consulta nula");}
            catch(Exception){pending=Task.FromResult(new DashboardSnapshot{Failure="No se pudo iniciar la consulta",CompletedUtc=DateTime.UtcNow});}
            return true;
        }
        // Solo se llama en el hilo UI. IsCompleted impide bloquearlo con Result.
        public bool Poll()
        {
            if(disposed||pending==null||!pending.IsCompleted)return false;
            try{Snapshot=pending.GetAwaiter().GetResult()??new DashboardSnapshot{Failure="Respuesta vacia",CompletedUtc=DateTime.UtcNow};}
            catch(Exception){Snapshot=new DashboardSnapshot{Failure="Consulta no disponible",CompletedUtc=DateTime.UtcNow};}
            finally{pending=null;cancellation.Dispose();cancellation=null;}
            return true;
        }
        public void Dispose()
        {
            if(disposed)return;disposed=true;
            CancellationTokenSource source=cancellation;
            if(source==null)return;
            source.Cancel();cancellation=null;
            if(pending!=null&&!pending.IsCompleted){pending.ContinueWith(t=>{if(t.IsFaulted){AggregateException observed=t.Exception;}source.Dispose();},TaskScheduler.Default);}
            else{if(pending!=null&&pending.IsFaulted){AggregateException observed=pending.Exception;}source.Dispose();}
            pending=null;
        }
    }
    public enum ToolAvailability {Available,RequiresAdministrator,Unsupported,Unknown,PendingIntegration}
    public static class ToolStateText
    {
        public static string Describe(ToolAvailability state)
        {
            switch(state){case ToolAvailability.Available:return "Disponible";case ToolAvailability.RequiresAdministrator:return "Requiere administrador";case ToolAvailability.Unsupported:return "No compatible";case ToolAvailability.Unknown:return "Estado desconocido";default:return "Pendiente de integración";}
        }
    }
    public sealed class DashboardCard
    {
        public string Key,Title,Value,Detail,State;
    }
    public static class DashboardNumbers
    {
        public static ulong? Parse(string value)
        {ulong parsed;return UInt64.TryParse(value,NumberStyles.None,CultureInfo.InvariantCulture,out parsed)?(ulong?)parsed:null;}
    }
    public static class DashboardPresentation
    {
        public const string Missing="No disponible";
        private static readonly CultureInfo Spanish=CultureInfo.GetCultureInfo("es-AR");
        public static ulong? Number(string value)
        {return DashboardNumbers.Parse(value);}
        public static string Bytes(ulong? bytes)
        {
            if(!bytes.HasValue)return Missing;
            string[] units={"B","KiB","MiB","GiB","TiB","PiB","EiB"};decimal size=bytes.Value;int unit=0;
            while(size>=1024&&unit<units.Length-1){size/=1024;unit++;}
            return size.ToString("0.##",Spanish)+" "+units[unit];
        }
        public static decimal? UsedPercent(ulong? total,ulong? available)
        {
            if(!total.HasValue||!available.HasValue||total.Value==0||available.Value>total.Value)return null;
            return Math.Round(100m*(total.Value-available.Value)/total.Value,1,MidpointRounding.AwayFromZero);
        }
        public static string Percent(decimal? value){return value.HasValue?value.Value.ToString("0.#",Spanish)+" %":Missing;}
        private static string Field(DashboardReading reading,string name)
        {
            string value;if(reading==null||reading.Fields==null||!reading.Fields.TryGetValue(name,out value)||String.IsNullOrWhiteSpace(value))return Missing;
            // Solo datos, nunca caracteres de control de proveedor en las etiquetas.
            return value.Replace("\r"," ").Replace("\n"," ").Replace("\t"," ").Trim();
        }
        private static ulong? Numeric(DashboardReading reading,string name,bool positive)
        {ulong? n=Number(Field(reading,name));return positive&&n==0?null:n;}
        private static string Count(DashboardReading reading,string name)
        {ulong? n=Numeric(reading,name,true);return n.HasValue?n.Value.ToString(Spanish):Missing;}
        public static DashboardCard Card(string key,DashboardSnapshot snapshot,bool loading)
        {
            DashboardReading r;snapshot.Readings.TryGetValue(key,out r);
            DashboardCard card=new DashboardCard{Key=key,Value=Missing,Detail="",State=loading?"Consultando…":Missing};
            switch(key){
                case "os":
                    card.Title="Sistema operativo";card.Value=Field(r,"Caption");
                    card.Detail="Versión: "+Field(r,"Version")+" · Compilación: "+Field(r,"Build")+"\nArquitectura: "+Field(r,"Architecture");break;
                case "cpu":
                    card.Title="Procesador";card.Value=Field(r,"Name");card.Detail="Núcleos físicos: "+Count(r,"Cores")+"\nProcesadores lógicos: "+Count(r,"Logical");break;
                case "ram":
                    card.Title="Memoria RAM";card.Value=Bytes(Numeric(r,"Installed",true));
                    ulong? usable=Numeric(r,"Usable",true),free=Numeric(r,"Available",false);
                    if(usable.HasValue&&free>usable)free=null;
                    card.Detail="Instalada · Disponible: "+Bytes(free)+"\nUso: "+Percent(UsedPercent(usable,free))+" de "+Bytes(usable)+" utilizables";break;
                case "disk":
                    card.Title="Almacenamiento";ulong? total=Numeric(r,"Total",true),space=Numeric(r,"Available",false);
                    if(total.HasValue&&space>total)space=null;
                    card.Value=Bytes(total);card.Detail="Unidad del sistema: "+Field(r,"Drive")+"\nDisponible: "+Bytes(space)+" · Uso: "+Percent(UsedPercent(total,space));break;
                case "power":
                    card.Title="Plan de energía";card.Value=Field(r,"Name");card.Detail=card.Value==Missing?"Plan activo: estado desconocido":"Plan activo · Solo lectura";break;
                default:throw new ArgumentException("Tarjeta desconocida");
            }
            if(loading&&r==null){card.Value="Consultando…";card.Detail="Consulta de solo lectura en curso.";return card;}
            if(loading){card.State="Lectura anterior";return card;}
            if(card.Value==Missing&&(r==null||r.Fields.Count==0)){card.State=Missing;}
            else if(card.Value==Missing||card.Detail.Contains(Missing)||r==null||!String.IsNullOrEmpty(r.Failure)){card.State="Datos parciales";}
            else card.State="Disponible";
            return card;
        }
        public static string Status(DashboardController controller)
        {
            if(controller.IsBusy)return controller.Snapshot.Readings.Count>0?"Actualizando… Se muestra la lectura anterior. Puedes seguir navegando.":"Consultando información… Puedes seguir navegando.";
            DashboardSnapshot snapshot=controller.Snapshot;
            if(!controller.HasRequested)return "Información aún no consultada.";
            if(snapshot.TimedOut)return "Tiempo de espera agotado · Algunas lecturas pueden no estar disponibles.";
            bool partial=!String.IsNullOrEmpty(snapshot.Failure);
            foreach(string key in DashboardWire.Keys)if(Card(key,snapshot,false).State!="Disponible")partial=true;
            string time=snapshot.CompletedUtc.HasValue?snapshot.CompletedUtc.Value.ToLocalTime().ToString("HH:mm:ss",Spanish):Missing;
            return (partial?"Lectura parcial":"Lectura completada")+" · "+time+" · Actualización manual";
        }
    }
}
