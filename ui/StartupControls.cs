using System;
using System.Drawing;
using System.Windows.Forms;
namespace Juno.Preview
{
    internal sealed class StartupListRow : Panel
    {
        private readonly float scale;
        private readonly Label application,state;
        private readonly Control action;
        private readonly bool header;
        public StartupListRow(float factor,Font font)
        {
            scale=factor;header=true;Name="StartupHeadings";BackColor=Colors.Card;
            application=new Label{Text="Aplicación",Font=font,ForeColor=Colors.Muted};
            state=new Label{Text="Estado",Font=font,ForeColor=Colors.Muted};
            action=new Label{Text="Acción",Font=font,ForeColor=Colors.Muted};
            Controls.Add(application);Controls.Add(state);Controls.Add(action);
        }
        public StartupListRow(StartupEntry entry,int index,float factor,Font font,bool busy,Action change,Action explain)
        {
            scale=factor;Name="StartupRow"+index;BackColor=Colors.Card;
            application=new Label{Text=entry.Name+"\r\n"+entry.Scope,Font=font,ForeColor=Colors.Text,AutoEllipsis=true,TextAlign=ContentAlignment.MiddleLeft,AccessibleName=entry.Name+", "+entry.Scope};
            state=new Label{Text=entry.State=="Enabled"?"Activado":entry.State=="Disabled"?"Desactivado":"No disponible",Font=font,ForeColor=entry.State=="Enabled"?Colors.Amber:Colors.Muted,TextAlign=ContentAlignment.MiddleLeft};
            var button=new PreviewButton{Name="StartupAction"+index,Text=entry.CanChange?(entry.NeedsReview?"Revisar":entry.State=="Enabled"?"Desactivar":"Activar"):"Revisar",Font=font,Secondary=true,Enabled=!busy,AccessibleDescription=entry.Reason};
            button.Click+=delegate{if(entry.CanChange)change();else explain();};action=button;
            var hint=new ToolTip();hint.SetToolTip(application,entry.Name+" · "+entry.Scope);hint.SetToolTip(button,entry.Reason);Disposed+=delegate{hint.Dispose();};
            Controls.Add(application);Controls.Add(state);Controls.Add(action);
        }
        public override Size GetPreferredSize(Size proposedSize){return new Size(proposedSize.Width,(int)((header?30:66)*scale));}
        protected override void OnLayout(LayoutEventArgs e)
        {
            int gap=(int)(8*scale),actionWidth=(int)(126*scale),stateWidth=(int)(100*scale);
            int nameWidth=Math.Max(1,ClientSize.Width-actionWidth-stateWidth-2*gap);
            application.SetBounds(0,0,nameWidth,Height);state.SetBounds(nameWidth+gap,0,stateWidth,Height);action.SetBounds(nameWidth+stateWidth+2*gap,header?0:(Height-(int)(38*scale))/2,actionWidth,header?Height:(int)(38*scale));
            base.OnLayout(e);
        }
        protected override void OnPaint(PaintEventArgs e){using(var pen=new Pen(Colors.Border)){e.Graphics.DrawLine(pen,0,Height-1,Width,Height-1);}base.OnPaint(e);}
    }
}
