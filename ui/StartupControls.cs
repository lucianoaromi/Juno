using System;
using System.Drawing;
using System.Windows.Forms;
namespace Juno.Preview
{
    internal sealed class StartupSettingsSection : Surface
    {
        private readonly float scale;
        private readonly Label title,description;
        private readonly PreviewButton settings;
        public StartupSettingsSection(float factor,Font normal,Font bold,bool enabled,Action open)
        {
            scale=factor;Name="startup";Padding=new Padding((int)(16*scale));AccessibleName="PROGRAMAS DE INICIO";
            title=new Label{Text="PROGRAMAS DE INICIO",Font=bold,ForeColor=Colors.Text};
            description=Tile.MakeLabel("Administrá qué aplicaciones se ejecutan automáticamente al iniciar Windows.",normal,Colors.Muted);
            settings=new PreviewButton{Name="StartupWindows",Text="Configurar en Windows",Font=normal,Secondary=true,Enabled=enabled};
            settings.Click+=delegate{if(settings.Enabled)open();};
            Controls.Add(title);Controls.Add(description);Controls.Add(settings);
        }
        private int DescriptionHeight(int width)
        {description.MaximumSize=new Size(width,0);return description.GetPreferredSize(new Size(width,0)).Height;}
        public override Size GetPreferredSize(Size proposedSize)
        {int width=Math.Max(1,proposedSize.Width-Padding.Horizontal);return new Size(proposedSize.Width,Padding.Vertical+(int)(80*scale)+DescriptionHeight(width));}
        protected override void OnLayout(LayoutEventArgs e)
        {
            if(title==null)return;
            int width=Math.Max(1,ClientSize.Width-Padding.Horizontal),y=Padding.Top;
            title.SetBounds(Padding.Left,y,width,(int)(26*scale));y+=(int)(34*scale);
            int textHeight=DescriptionHeight(width);description.SetBounds(Padding.Left,y,width,textHeight);y+=textHeight+(int)(12*scale);
            settings.SetBounds(Padding.Left,y,Math.Min(width,(int)(184*scale)),(int)(34*scale));
            base.OnLayout(e);
        }
    }
}
