using System;
using System.Drawing;
using System.Windows.Forms;

namespace Juno.Preview
{
    public sealed class TransparencyConfirmation : ITransparencyConfirmation
    {
        private readonly IWin32Window owner;
        public TransparencyConfirmation(IWin32Window parent){owner=parent;}
        public bool Confirm(string title,string message)
        {
            using(Form dialog=CreateDialog(title,message))return dialog.ShowDialog(owner)==DialogResult.OK;
        }
        public static Form CreateDialog(string title,string message)
        {
                Form dialog=new Form();
                Font font= new Font("Segoe UI",10);dialog.Disposed+=delegate{font.Dispose();};
                dialog.Text=title;dialog.StartPosition=FormStartPosition.CenterParent;
                dialog.BackColor=Colors.Canvas;dialog.ForeColor=Colors.Text;dialog.Font=font;
                bool review=title.IndexOf("Revisar recuperación",StringComparison.OrdinalIgnoreCase)>=0;
                dialog.Name=review?"RecoveryReview":"CompactConfirmation";
                dialog.Size=review?new Size(760,540):new Size(520,230);dialog.MinimumSize=review?new Size(480,360):new Size(360,210);
                dialog.MinimizeBox=false;dialog.MaximizeBox=false;dialog.ShowInTaskbar=false;
                dialog.Padding=new Padding(16);
                TextBox text=new TextBox{Name="ConfirmationMessage",Multiline=true,ReadOnly=true,WordWrap=true,ScrollBars=review||message.Length>180?ScrollBars.Vertical:ScrollBars.None,Dock=DockStyle.Fill,Text=message,BackColor=Colors.Canvas,ForeColor=Colors.Text,BorderStyle=BorderStyle.None,TabStop=false};
                FlowLayoutPanel actions=new FlowLayoutPanel{Dock=DockStyle.Bottom,Height=54,FlowDirection=FlowDirection.RightToLeft,Padding=new Padding(0,10,0,0)};
                PreviewButton cancel=new PreviewButton{Text="Cancelar",Secondary=true,Width=125,Height=36,Font=font,DialogResult=DialogResult.Cancel};
                string verb=review?"Autorizar":message.IndexOf("restaurar",StringComparison.OrdinalIgnoreCase)>=0?"Restaurar":message.IndexOf("desactivar",StringComparison.OrdinalIgnoreCase)>=0?"Desactivar":message.IndexOf("crear",StringComparison.OrdinalIgnoreCase)>=0?"Crear y activar":title.IndexOf("Efectos visuales",StringComparison.OrdinalIgnoreCase)>=0?"Aplicar":"Activar";
                PreviewButton accept=new PreviewButton{Text=verb,Width=145,Height=36,Font=font,Accent=true,DialogResult=DialogResult.OK};
                actions.Controls.Add(accept);actions.Controls.Add(cancel);dialog.Controls.Add(text);dialog.Controls.Add(actions);
                dialog.AcceptButton=cancel;dialog.CancelButton=cancel;dialog.ActiveControl=cancel;
                dialog.Shown+=delegate{Rectangle area=Screen.FromControl(dialog).WorkingArea;dialog.MinimumSize=new Size(Math.Min(dialog.MinimumSize.Width,area.Width-24),Math.Min(dialog.MinimumSize.Height,area.Height-24));dialog.Size=new Size(Math.Min(dialog.Width,area.Width-24),Math.Min(dialog.Height,area.Height-24));cancel.Focus();};
                return dialog;
        }
    }

    // Traducción de instantáneas a texto breve; el diagnóstico original no se modifica.
    public static class ToolPresentation
    {
        private static string Problem(string outcome,string issue,bool pending,string message)
        {
            if(!String.IsNullOrEmpty(issue))return "El respaldo no es compatible. Revisá los detalles.";
            if(outcome=="Conflict")return "La configuración cambió fuera de JUNO. Revisá los detalles.";
            if(pending)return "Hay un cambio pendiente de revisión.";
            if(outcome=="Busy")return "Otra operación está en curso. Volvé a consultar.";
            if(outcome=="Failed")return "No se pudo completar el cambio. Revisá los detalles.";
            if((message??"").IndexOf("original no existe",StringComparison.OrdinalIgnoreCase)>=0)return "El plan anterior ya no está disponible. Revisá los detalles.";
            if((message??"").IndexOf("Sesión anterior interrumpida",StringComparison.OrdinalIgnoreCase)>=0)return "La sesión anterior se interrumpió. Revisá los detalles.";
            if(outcome=="Cancelled"||(message??"").IndexOf("cancelada",StringComparison.OrdinalIgnoreCase)>=0)return "Solicitud cancelada.";
            return null;
        }
        public static string PowerMessage(PowerController controller)
        {
            if(controller.IsBusy)return controller.IsWriting?"Aplicando cambio…":"Consultando…";
            PowerResult r=controller.Snapshot;string problem=Problem(r.Outcome,r.BackupIssue,r.Pending,r.Message);if(problem!=null)return problem;
            if(String.IsNullOrEmpty(r.ActiveGuid))return "Consultá el estado para continuar.";
            if(!r.Administrator)return "Necesitás permisos de administrador.";
            if(r.Availability=="Unsupported")return "Este equipo no admite el cambio de plan.";
            if(r.Outcome=="Restored")return "Configuración restaurada.";
            if(r.Outcome=="Applied")return r.HighActive?"Alto rendimiento activado.":"Plan elegido activado.";
            if(r.HighActive)return "Ya estás utilizando Alto rendimiento.";
            if(r.SelectionActive)return "Tu computadora está utilizando este plan.";
            if(r.Historical)return "El respaldo anterior necesita una revisión.";
            if(r.Availability=="Unknown")return "No se pudo determinar el estado. Revisá los detalles.";
            return r.RequiresCreation?"Alto rendimiento no está disponible.":r.RequiresSelection?"Elegí un plan para continuar.":"Plan actual de tu computadora.";
        }
        public static string TransparencyMessage(TransparencyController controller)
        {
            if(controller.IsBusy)return controller.IsWriting?"Aplicando cambio…":"Consultando…";
            TransparencyResult r=controller.Snapshot;string problem=Problem(r.Outcome,r.BackupIssue,r.Pending,r.Message);if(problem!=null)return problem;
            if(r.Outcome=="Restored")return "Configuración restaurada.";
            if(r.Outcome=="Applied")return "Cambio aplicado. El efecto puede requerir cerrar sesión.";
            if(r.Historical)return "El respaldo anterior necesita una revisión.";
            return r.State=="Enabled"||r.State=="Disabled"?"Apariencia de tu escritorio.":"No se pudo determinar el estado. Revisá los detalles.";
        }
        public static string PowerDetails(PowerController controller)
        {
            PowerResult r=controller.Snapshot;
            return "Plan: "+r.ActiveName+"\r\nGUID: "+r.ActiveGuid+"\r\nÁmbito: equipo (Machine)\r\nRequiere administrador: sí. Sesión elevada: "+r.Administrator+
                "\r\nModern Standby: "+r.ModernStandby+"\r\nDisponibilidad: "+r.Availability+"\r\nRespaldo: "+(r.BackupIssue??(r.CanRestore?"Restauración disponible":"Sin restauración disponible"))+
                "\r\nPendiente: "+r.Pending+"\r\nHistórico: "+r.Historical+"\r\nResultado: "+r.Outcome+"\r\nPuede activar: "+r.CanApply+"\r\nPreferencia de esta sesión: "+controller.RememberedGuid+
                "\r\n\r\n"+controller.Status+"\r\n\r\nPlanes enumerados:\r\n"+String.Join("\r\n",r.Plans)+
                "\r\n\r\nSe conserva el plan original y el diario de operaciones. No se eliminan planes. Los nombres no acreditan equivalencia de ajustes. Alto rendimiento puede aumentar el consumo y la temperatura; no garantiza una mejora universal.\r\nSi faltan permisos, cerrá JUNO y abrilo como administrador con la misma cuenta. No cambies de usuario para acceder a respaldos.";
        }
        public static string TransparencyDetails(TransparencyController controller)
        {
            TransparencyResult r=controller.Snapshot;
            return "Ámbito: usuario actual (HKCU)\r\nRequiere administrador: no\r\nEstado del Registro: "+r.State+"\r\nRespaldo: "+(r.BackupIssue??(r.CanRestore?"Restauración disponible":"Sin restauración disponible"))+
                "\r\nPendiente: "+r.Pending+"\r\nHistórico: "+r.Historical+"\r\nResultado: "+r.Outcome+"\r\nPuede cambiar: "+r.CanChange+"\r\n\r\n"+controller.Status+
                "\r\n\r\nSe conserva el valor original, incluida su ausencia. Se verifica el Registro; el estado no garantiza el efecto visual. Puede requerir cerrar sesión manualmente. JUNO no reinicia Explorer. La recuperación histórica conserva su revisión explícita.";
        }
    }
}
