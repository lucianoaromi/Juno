using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace Juno.Preview
{
    internal sealed class RecoveryRow : Panel
    {
        private readonly float scale;private readonly Label title,message;private readonly PreviewButton restore;
        public RecoveryRow(RecoveryItem item,float factor,Font normal,Font bold,bool enabled,Action<string> action)
        {
            scale=factor;Name="RecoveryRow"+item.Id;BackColor=Colors.Card;
            title=Tile.MakeLabel(RecoveryPresentation.Name(item.Id),bold,Colors.Text);message=Tile.MakeLabel(RecoveryPresentation.Message(item),normal,Colors.Muted);
            Controls.Add(title);Controls.Add(message);
            if(item.CanRestore){restore=new PreviewButton{Name=item.Id=="Startup"?"StartupRestore":item.Id+"RecoveryRestore",Text="Restaurar",Font=normal,Secondary=true,Enabled=enabled};restore.Click+=delegate{if(restore.Enabled)action(item.Id);};Controls.Add(restore);}
            Paint+=delegate(object sender,PaintEventArgs e){using(var pen=new Pen(Colors.Border))e.Graphics.DrawLine(pen,0,Height-1,Width,Height-1);};
        }
        private bool Wide(int width){return width>=(int)(470*scale);}
        private int TextHeight(Label label,int width){label.MaximumSize=new Size(Math.Max(1,width),0);return label.GetPreferredSize(new Size(Math.Max(1,width),0)).Height;}
        public override Size GetPreferredSize(Size proposedSize)
        {
            int width=Math.Max(1,proposedSize.Width-(Wide(proposedSize.Width)&&restore!=null?(int)(135*scale):0));
            int height=TextHeight(title,width)+TextHeight(message,width)+(int)(12*scale);
            if(restore!=null&&!Wide(proposedSize.Width))height+=(int)(42*scale);
            return new Size(proposedSize.Width,Math.Max(height,(int)(60*scale)));
        }
        protected override void OnLayout(LayoutEventArgs e)
        {
            if(title==null)return;
            int width=Math.Max(1,ClientSize.Width-(Wide(ClientSize.Width)&&restore!=null?(int)(135*scale):0));
            int h=TextHeight(title,width);title.SetBounds(0,0,width,h);int m=TextHeight(message,width);message.SetBounds(0,h+(int)(3*scale),width,m);
            if(restore!=null){int y=Wide(ClientSize.Width)?(int)(8*scale):message.Bottom+(int)(7*scale);restore.SetBounds(Wide(ClientSize.Width)?ClientSize.Width-(int)(116*scale):0,y,Math.Min(ClientSize.Width,(int)(116*scale)),(int)(32*scale));}
            base.OnLayout(e);
        }
    }
    internal sealed class RecoverySection : Surface
    {
        private readonly float scale;private readonly Label title,description,status;private readonly PreviewButton read;
        private readonly List<RecoveryRow> rows=new List<RecoveryRow>();
        public RecoverySection(RecoveryController controller,float factor,Font normal,Font bold,bool enabled,Action refresh,Action<string> restore)
        {
            scale=factor;Name="RecoverySection";Padding=new Padding((int)(16*scale));
            title=Tile.MakeLabel("RESTAURACIÓN",bold,Colors.Text);description=Tile.MakeLabel("Recuperá las configuraciones anteriores de JUNO.",normal,Colors.Muted);
            status=Tile.MakeLabel(controller.Status,normal,Colors.Muted);status.Name="RecoveryStatus";
            Controls.Add(title);Controls.Add(description);Controls.Add(status);
            foreach(var item in controller.Snapshot.Items)if(item.State!="Empty"){
                var row=new RecoveryRow(item,scale,normal,bold,enabled&&controller.CanRestore(item.Id),restore);rows.Add(row);Controls.Add(row);
            }
            read=new PreviewButton{Name="RecoveryRead",Text="Comprobar respaldos",Font=normal,Secondary=true,Enabled=enabled&&controller.IsConfigured};read.Click+=delegate{if(read.Enabled)refresh();};Controls.Add(read);
        }
        private int LabelHeight(Label label,int width){label.MaximumSize=new Size(Math.Max(1,width),0);return label.GetPreferredSize(new Size(Math.Max(1,width),0)).Height;}
        public override Size GetPreferredSize(Size proposedSize)
        {
            int width=Math.Max(1,proposedSize.Width-Padding.Horizontal);
            int h=Padding.Vertical+LabelHeight(title,width)+LabelHeight(description,width)+LabelHeight(status,width)+(int)(65*scale);
            foreach(var row in rows)h+=row.GetPreferredSize(new Size(width,0)).Height+(int)(10*scale);
            return new Size(proposedSize.Width,h);
        }
        protected override void OnLayout(LayoutEventArgs e)
        {
            if(title==null||read==null)return;int width=Math.Max(1,ClientSize.Width-Padding.Horizontal),y=Padding.Top;
            foreach(var label in new[]{title,description,status}){int h=LabelHeight(label,width);label.SetBounds(Padding.Left,y,width,h);y+=h+(int)(8*scale);}
            foreach(var row in rows){int h=row.GetPreferredSize(new Size(width,0)).Height;row.SetBounds(Padding.Left,y,width,h);y+=h+(int)(10*scale);}
            read.SetBounds(Padding.Left,y,Math.Min(width,(int)(200*scale)),(int)(34*scale));base.OnLayout(e);
        }
    }
}
