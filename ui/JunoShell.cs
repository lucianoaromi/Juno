// C# 5 / .NET Framework, compilado en memoria por Windows PowerShell 5.1.
// Presentacion: recibe instantaneas, sin proveedores de hardware ni motores estables.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Juno.Preview
{
    public static class PreviewHost
    {
        [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
        public static void Initialize()
        {
            // System-aware, antes de crear controles. No modifica powershell.exe.config.
            SetProcessDPIAware();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
        }
    }

    internal static class Colors
    {
        public static readonly Color Canvas = Color.FromArgb(13, 17, 23);
        public static readonly Color Sidebar = Color.FromArgb(17, 22, 30);
        public static readonly Color Card = Color.FromArgb(23, 29, 39);
        public static readonly Color Border = Color.FromArgb(42, 50, 64);
        public static readonly Color Text = Color.FromArgb(238, 241, 246);
        public static readonly Color Muted = Color.FromArgb(157, 168, 184);
        public static readonly Color Amber = Color.FromArgb(234, 185, 98);
        public static readonly Color Selected = Color.FromArgb(49, 42, 31);
    }

    internal static class Shapes
    {
        public static GraphicsPath Round(RectangleF rect, float radius)
        {
            float d = Math.Max(1, Math.Min(radius * 2, Math.Min(rect.Width, rect.Height)));
            GraphicsPath path = new GraphicsPath();
            path.AddArc(rect.X, rect.Y, d, d, 180, 90);
            path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
            path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
            path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
            path.CloseFigure(); return path;
        }
        // Iconos vectoriales discretos, sin fuentes de iconos ni dependencias externas.
        public static void Icon(Graphics g, string kind, RectangleF rect, Color color)
        {
            GraphicsState state = g.Save();
            g.TranslateTransform(rect.X, rect.Y); g.ScaleTransform(rect.Width / 24f, rect.Height / 24f);
            using (Pen p = new Pen(color, 1.5f))
            {
                p.StartCap = p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
                switch (kind)
                {
                    case "Inicio":
                        g.DrawLines(p, new PointF[] { new PointF(3,11),new PointF(12,3),new PointF(21,11) });
                        g.DrawLines(p, new PointF[] { new PointF(5,10),new PointF(5,21),new PointF(10,21),new PointF(10,15),new PointF(14,15),new PointF(14,21),new PointF(19,21),new PointF(19,10) }); break;
                    case "Rendimiento": case "power":
                        g.DrawLines(p,new PointF[]{new PointF(14,2),new PointF(5,14),new PointF(11,14),new PointF(10,22),new PointF(20,9),new PointF(13,9),new PointF(14,2)}); break;
                    case "Aplicaciones": case "cpu":
                        for(int y=0;y<2;y++) for(int x=0;x<2;x++) g.DrawRectangle(p,4+x*10,4+y*10,6,6); break;
                    case "Mantenimiento": case "disk":
                        g.DrawRectangle(p,3,6,18,12);g.DrawLine(p,3,14,21,14);g.DrawEllipse(p,16,15.5f,1,1);break;
                    case "Restauración":
                        g.DrawArc(p,4,4,16,16,215,285);g.DrawLines(p,new PointF[]{new PointF(3,3),new PointF(3,9),new PointF(9,9)});g.DrawLines(p,new PointF[]{new PointF(12,7),new PointF(12,12),new PointF(16,14)});break;
                    case "Acerca de":
                        g.DrawEllipse(p,3,3,18,18);g.DrawLine(p,12,11,12,17);g.DrawEllipse(p,11.5f,6.5f,1,1);break;
                    case "ram":
                        g.DrawRectangle(p,3,7,18,10);for(int x=6;x<20;x+=4){g.DrawLine(p,x,4,x,7);g.DrawLine(p,x,17,x,20);}g.DrawRectangle(p,7,10,4,4);g.DrawRectangle(p,14,10,3,4);break;
                    default:
                        g.DrawRectangle(p,3,4,18,13);g.DrawLine(p,8,21,16,21);g.DrawLine(p,12,17,12,21);break;
                }
            }
            g.Restore(state);
        }
    }

    internal class Surface : Panel
    {
        public Surface()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Colors.Card; Padding = new Padding(22); Margin = new Padding(0);
        }
        public override Size GetPreferredSize(Size proposedSize)
        {
            VStack content=Tag as VStack;
            if(content!=null)return new Size(proposedSize.Width,content.GetPreferredSize(new Size(Math.Max(1,proposedSize.Width-Padding.Horizontal),0)).Height+Padding.Vertical);
            return base.GetPreferredSize(proposedSize);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath path = Shapes.Round(new RectangleF(.5f,.5f,Width-1,Height-1),12 * e.Graphics.DpiX / 96f))
            using (Pen pen = new Pen(Colors.Border)) { e.Graphics.DrawPath(pen,path); }
            base.OnPaint(e);
        }
    }

    internal class Glyph : Control
    {
        public string Kind;
        public Glyph(string kind) { Kind=kind; Size=new Size(24,24); SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint,true); TabStop=false; }
        protected override void OnPaint(PaintEventArgs e)
        { e.Graphics.SmoothingMode=SmoothingMode.AntiAlias; Shapes.Icon(e.Graphics,Kind,new RectangleF(2,2,Width-4,Height-4),Colors.Amber); }
    }

    internal class PreviewButton : Button
    {
        public bool Accent;
        public string GlyphName;
        public bool Selected;
        private bool hover;
        public PreviewButton()
        {
            FlatStyle=FlatStyle.Flat;FlatAppearance.BorderSize=0;
            BackColor=Colors.Card;ForeColor=Colors.Text;Cursor=Cursors.Hand;
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw,true);
            TextAlign=ContentAlignment.MiddleLeft;AccessibleRole=AccessibleRole.PushButton;
        }
        protected override void OnMouseEnter(EventArgs e){hover=true;Invalidate();base.OnMouseEnter(e);}
        protected override void OnMouseLeave(EventArgs e){hover=false;Invalidate();base.OnMouseLeave(e);}
        public override Size GetPreferredSize(Size proposedSize){return new Size(proposedSize.Width,Height);}
        protected override void OnPaint(PaintEventArgs e)
        {
            float s=e.Graphics.DpiX/96f;
            Color bg=Selected?Colors.Selected:(Accent?Colors.Amber:(hover&&Enabled?Color.FromArgb(33,41,54):BackColor));
            Color fg=Selected?Colors.Amber:(Accent?Colors.Canvas:(Enabled?Colors.Text:Colors.Muted));
            if(!Enabled&&Accent){bg=Colors.Selected;fg=Colors.Muted;}
            e.Graphics.Clear(BackColor);e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
            using(GraphicsPath path=Shapes.Round(new RectangleF(.5f,.5f,Width-1,Height-1),8*s))
            using(SolidBrush brush=new SolidBrush(bg)) {e.Graphics.FillPath(brush,path);}
            int left=(int)(16*s);
            if(GlyphName!=null){Shapes.Icon(e.Graphics,GlyphName,new RectangleF(left,(Height-20*s)/2,20*s,20*s),fg);left+=(int)(34*s);}
            if(Selected) using(SolidBrush b=new SolidBrush(Colors.Amber)){e.Graphics.FillRectangle(b,0,Height/2-10*s,3*s,20*s);}
            TextRenderer.DrawText(e.Graphics,Text,Font,new Rectangle(left,0,Width-left-(int)(12*s),Height),fg,TextFormatFlags.VerticalCenter|TextFormatFlags.Left|TextFormatFlags.NoPrefix);
            if(Focused&&ShowFocusCues)ControlPaint.DrawFocusRectangle(e.Graphics,new Rectangle(5,5,Width-10,Height-10),fg,bg);
        }
    }

    // Vertical auto-size: textos medidos con su ancho actual, sin alturas fijas para etiquetas.
    internal class VStack : Panel
    {
        public int Gap=10;
        public override Size GetPreferredSize(Size proposedSize)
        {
            int width=Math.Max(1,proposedSize.Width-Padding.Horizontal),height=Padding.Vertical;
            foreach(Control c in Controls) {Label label=c as Label;if(label!=null)label.MaximumSize=new Size(width,0);height+=c.GetPreferredSize(new Size(width,0)).Height+Gap;}
            return new Size(proposedSize.Width,Math.Max(0,height-Gap));
        }
        protected override void OnLayout(LayoutEventArgs e)
        {
            int y=Padding.Top; int width=Math.Max(1,ClientSize.Width-Padding.Horizontal);
            foreach(Control c in Controls){Size size=c.GetPreferredSize(new Size(width,0));c.SetBounds(Padding.Left,y,c is Glyph?Math.Min(width,size.Width):width,size.Height);y+=size.Height+Gap;}
            base.OnLayout(e);
        }
    }

    internal class Tile : Surface
    {
        public string Key {get;private set;}
        private readonly VStack stack;
        private readonly Label title,detail,value;
        public Tile(string key,string heading,string text,Font normal,Font bold,Font large,string displayValue,bool tool,float scale)
        {
            Key=key;Name=key;AccessibleName=heading;
            Padding=new Padding((int)(20*scale));
            stack=new VStack();stack.Gap=(int)(8*scale);stack.BackColor=Colors.Card;
            Glyph icon=new Glyph(key);icon.Size=new Size((int)(24*scale),(int)(24*scale));icon.AccessibleName=heading+" (icono)";
            title=MakeLabel(heading,bold,Colors.Text);
            detail=MakeLabel(text,normal,Colors.Muted);
            stack.Controls.Add(icon);stack.Controls.Add(title);
            if(displayValue!=null){value=MakeLabel(displayValue,large,Colors.Text);stack.Controls.Add(value);}
            stack.Controls.Add(detail);
            if(tool){
                Label state=MakeLabel(ToolStateText.Describe(ToolAvailability.PendingIntegration),normal,Colors.Amber);state.Name="ToolState";stack.Controls.Add(state);
                PreviewButton action=new PreviewButton();action.Text="Sin conectar";action.Name="ToolAction";action.AccessibleDescription="Herramienta no conectada en este prototipo";action.Enabled=false;action.Font=normal;action.Height=(int)(40*scale);action.Dock=DockStyle.None;
                stack.Controls.Add(action);
            }
            Controls.Add(stack);
        }
        internal static Label MakeLabel(string text,Font font,Color color)
        {return new Label{Text=text,Font=font,ForeColor=color,AutoSize=true,BackColor=Color.Transparent,UseMnemonic=false,Margin=Padding.Empty};}
        public void SetReadingState(string text,Font font)
        {Label state=MakeLabel(text,font,Colors.Muted);state.Name="ReadingState";stack.Controls.Add(state);}
        private void SetWidths(int width)
        {foreach(Control c in stack.Controls){Label label=c as Label;if(label!=null)label.MaximumSize=new Size(Math.Max(1,width),0);}}
        public override Size GetPreferredSize(Size proposedSize)
        {
            int width=Math.Max(1,proposedSize.Width-Padding.Horizontal);SetWidths(width);
            return new Size(proposedSize.Width,stack.GetPreferredSize(new Size(width,0)).Height+Padding.Vertical);
        }
        protected override void OnLayout(LayoutEventArgs e)
        {
            if(stack!=null){int width=Math.Max(1,ClientSize.Width-Padding.Horizontal);SetWidths(width);stack.SetBounds(Padding.Left,Padding.Top,width,Math.Max(1,ClientSize.Height-Padding.Vertical));}
            base.OnLayout(e);
        }
    }

    internal class TileGrid : Panel
    {
        public int MaxColumns=3;
        public float UiScale=1;
        public int Columns {get;private set;}
        public override Size GetPreferredSize(Size proposedSize)
        {return Arrange(Math.Max(1,proposedSize.Width),false);}
        private Size Arrange(int width,bool apply)
        {
            int gap=(int)(16*UiScale);
            Columns=Math.Max(1,Math.Min(MaxColumns,(width+gap)/Math.Max(1,(int)(230*UiScale)+gap)));
            int cell=Math.Max(1,(width-gap*(Columns-1))/Columns),y=0;
            for(int i=0;i<Controls.Count;i+=Columns){
                int h=0;
                for(int j=i;j<Math.Min(i+Columns,Controls.Count);j++)h=Math.Max(h,Controls[j].GetPreferredSize(new Size(cell,0)).Height);
                for(int j=i;j<Math.Min(i+Columns,Controls.Count);j++)if(apply)Controls[j].SetBounds((j-i)*(cell+gap),y,cell,h);
                y+=h+gap;
            }
            return new Size(width,Math.Max(0,y-gap));
        }
        protected override void OnLayout(LayoutEventArgs e){Arrange(ClientSize.Width,true);base.OnLayout(e);}
    }

    public class ShellForm : Form
    {
        public const string PreviewVersion="0.9 · Etapa 2";
        public const string RepositoryUrl="https://github.com/lucianoaromi/Juno";
        public static readonly string[] Sections={"Inicio","Rendimiento","Aplicaciones","Mantenimiento","Restauración","Acerca de"};
        public string SelectedSection {get;private set;}
        public bool ResourcesReleased {get;private set;}
        private readonly Dictionary<string,PreviewButton> navigation=new Dictionary<string,PreviewButton>();
        private readonly List<Font> fonts=new List<Font>();
        private readonly List<IDisposable> assets=new List<IDisposable>();
        private Panel sidebar,main,header,footer,viewport;
        private VStack page;
        private Label breadcrumb,status;
        private Font normal,small,bold,heading,metric;
        private Bitmap logo;
        private float scale=1;
        private bool layingOut;
        private readonly DashboardController dashboard;
        private readonly Timer dashboardTimer;
        private Label dashboardStatus;
        public DashboardController Dashboard {get{return dashboard;}}

        public ShellForm(string assetRoot):this(assetRoot,new DashboardController(new UnavailableDashboardQuery())){}
        public ShellForm(string assetRoot,DashboardController controller)
        {
            if(controller==null)throw new ArgumentNullException("controller");dashboard=controller;
            dashboardTimer=new Timer();dashboardTimer.Interval=100;dashboardTimer.Tick+=delegate{if(dashboard.Poll())RefreshDashboardView();if(!dashboard.IsBusy)dashboardTimer.Stop();};
            Text="JUNO v0.9 | Prototipo de interfaz";Name="JunoPreview";
            StartPosition=FormStartPosition.CenterScreen;
            BackColor=Colors.Canvas;ForeColor=Colors.Text;
            normal=OwnFont(10,FontStyle.Regular);small=OwnFont(9,FontStyle.Regular);bold=OwnFont(11,FontStyle.Bold);
            heading=OwnFont(24,FontStyle.Bold);metric=OwnFont(16,FontStyle.Bold);
            // Una sola estrategia: medidas logicas * DPI del proceso, fuentes en puntos.
            // No combina escalado automatico y manual ni reconfigura el host PowerShell.
            Font=normal;AutoScaleMode=AutoScaleMode.None;
            using(Graphics g=CreateGraphics()){scale=g.DpiX/96f;}
            ClientSize=new Size((int)(1180*scale),(int)(790*scale));MinimumSize=new Size((int)(690*scale),(int)(500*scale));
            SetStyle(ControlStyles.OptimizedDoubleBuffer|ControlStyles.AllPaintingInWmPaint,true);
            LoadLogo(assetRoot);
            sidebar=new Panel{BackColor=Colors.Sidebar,Name="Sidebar",AutoScroll=true};
            header=new Panel{BackColor=Colors.Canvas,Name="Header"};
            main=new Panel{BackColor=Colors.Canvas,Name="Main"};
            footer=new Panel{BackColor=Colors.Canvas,Name="Footer"};
            viewport=new Panel{BackColor=Colors.Canvas,AutoScroll=true,Name="ContentViewport"};
            page=new VStack{BackColor=Colors.Canvas,Name="Page",Gap=(int)(20*scale)};
            viewport.Controls.Add(page);main.Controls.Add(viewport);
            Controls.AddRange(new Control[]{sidebar,main,header,footer});
            BuildSidebar();BuildHeader();BuildFooter();
            viewport.SizeChanged+=delegate{LayoutPage();};
            Navigate("Inicio");PerformLayout();
        }
        private Font OwnFont(float size,FontStyle style){Font f=new Font("Segoe UI",size,style,GraphicsUnit.Point);fonts.Add(f);return f;}
        private void LoadLogo(string root)
        {
            try{using(Icon source=new Icon(System.IO.Path.Combine(root,"Juno.ico"))){Icon=(Icon)source.Clone();assets.Add(Icon);logo=source.ToBitmap();assets.Add(logo);}}
            catch(System.IO.IOException){}catch(ArgumentException){}catch(UnauthorizedAccessException){}
        }
        private void BuildSidebar()
        {
            PictureBox picture=new PictureBox{Image=logo,SizeMode=PictureBoxSizeMode.Zoom,Name="BrandIcon",TabStop=false};
            Label brand=Tile.MakeLabel("JUNO",OwnFont(20,FontStyle.Bold),Colors.Text);brand.Name="BrandName";
            Label version=Tile.MakeLabel("v0.9  /  VISTA PREVIA",OwnFont(8,FontStyle.Bold),Colors.Muted);version.Name="BrandVersion";
            sidebar.Controls.AddRange(new Control[]{picture,brand,version});
            Label group=Tile.MakeLabel("ESPACIO DE TRABAJO",OwnFont(8,FontStyle.Bold),Colors.Muted);group.Name="NavGroup";sidebar.Controls.Add(group);
            foreach(string section in Sections){
                PreviewButton button=new PreviewButton{Text=section,GlyphName=section,BackColor=Colors.Sidebar,Font=normal,Name="Nav"+section,AccessibleName=section};
                string destination=section;button.Click+=delegate{Navigate(destination);};
                navigation.Add(section,button);sidebar.Controls.Add(button);
            }
            Label notice=Tile.MakeLabel("PROTOTIPO VISUAL\nOperaciones sin conectar",small,Colors.Muted);notice.Name="NavNotice";sidebar.Controls.Add(notice);
        }
        private void BuildHeader()
        {
            breadcrumb=Tile.MakeLabel("ESPACIO DE TRABAJO  /  Inicio",small,Colors.Muted);breadcrumb.AutoSize=false;breadcrumb.AutoEllipsis=true;header.Controls.Add(breadcrumb);
            Label badge=Tile.MakeLabel("●  SOLO LECTURA",OwnFont(8,FontStyle.Bold),Colors.Amber);badge.Name="InformationBadge";badge.AutoSize=false;badge.TextAlign=ContentAlignment.MiddleRight;header.Controls.Add(badge);
            header.Paint+=delegate(object sender,PaintEventArgs e){using(Pen pen=new Pen(Colors.Border)){e.Graphics.DrawLine(pen,0,header.Height-1,header.Width,header.Height-1);}};
        }
        private void BuildFooter()
        {
            status=Tile.MakeLabel("Dashboard de solo lectura · Herramientas pendientes de integración",small,Colors.Muted);status.Name="PreviewStatus";footer.Controls.Add(status);
        }
        private Label TextLabel(string text,Font font,Color color){return Tile.MakeLabel(text,font,color);}
        private VStack Intro(string eyebrow,string title,string description)
        {
            VStack stack=new VStack{Gap=(int)(8*scale)};
            stack.Controls.Add(TextLabel(eyebrow,small,Colors.Amber));stack.Controls.Add(TextLabel(title,heading,Colors.Text));stack.Controls.Add(TextLabel(description,normal,Colors.Muted));return stack;
        }
        private TileGrid Grid(int columns){return new TileGrid{MaxColumns=columns,UiScale=scale,Name="Tiles"};}
        private Tile Tool(string key,string title,string detail){return new Tile(key,title,detail,normal,bold,metric,null,true,scale);}

        public void Navigate(string section)
        {
            if(!navigation.ContainsKey(section))throw new ArgumentException("Sección desconocida.","section");
            viewport.AutoScrollPosition=Point.Empty;
            while(page.Controls.Count>0){Control old=page.Controls[0];page.Controls.Remove(old);old.Dispose();}
            dashboardStatus=null;
            SelectedSection=section;breadcrumb.Text="ESPACIO DE TRABAJO  /  "+section;
            foreach(KeyValuePair<string,PreviewButton> pair in navigation){pair.Value.Selected=pair.Key==section;pair.Value.AccessibleDescription=pair.Value.Selected?"Sección seleccionada":"Ir a "+pair.Key;pair.Value.Invalidate();}
            status.Text="Dashboard de solo lectura · Herramientas pendientes de integración";
            header.Controls["InformationBadge"].Text=section=="Inicio"?"●  LECTURA DEL SISTEMA":"●  HERRAMIENTAS SIN CONECTAR";
            switch(section){
                case "Inicio":BuildHome();break;
                case "Rendimiento":BuildPerformance();break;
                case "Aplicaciones":BuildApps();break;
                case "Mantenimiento":BuildMaintenance();break;
                case "Restauración":BuildRecovery();break;
                case "Acerca de":BuildAbout();break;
            }
            LayoutPage();
        }
        private void BuildHome()
        {
            page.Controls.Add(Intro("TU EQUIPO","Información del sistema","Una instantánea de Windows. Consultas de solo lectura, sin monitoreo continuo."));
            VStack toolbar=new VStack{Gap=(int)(8*scale),Name="DashboardToolbar"};
            PreviewButton refresh=new PreviewButton{Text=dashboard.IsBusy?"Actualizando información…":"Actualizar información",Accent=true,Font=normal,Height=(int)(42*scale),Name="RefreshInformation",Enabled=!dashboard.IsBusy};
            refresh.Click+=delegate{RefreshInformation();};toolbar.Controls.Add(refresh);
            dashboardStatus=TextLabel(DashboardPresentation.Status(dashboard),normal,Colors.Muted);dashboardStatus.Name="DashboardState";toolbar.Controls.Add(dashboardStatus);page.Controls.Add(toolbar);
            TileGrid grid=Grid(3);
            foreach(string key in DashboardWire.Keys){DashboardCard data=DashboardPresentation.Card(key,dashboard.Snapshot,dashboard.IsBusy);Tile tile=new Tile(key,data.Title,data.Detail,normal,bold,metric,data.Value,false,scale);tile.SetReadingState(data.State,small);tile.AccessibleDescription=data.State;grid.Controls.Add(tile);}
            page.Controls.Add(grid);
        }
        public bool RefreshInformation()
        {
            if(!dashboard.Refresh())return false;
            RefreshDashboardView();dashboardTimer.Start();return true;
        }
        private void RefreshDashboardView()
        {
            if(IsDisposed||Disposing)return;
            if(SelectedSection=="Inicio"){
                int scroll=-viewport.AutoScrollPosition.Y;
                while(page.Controls.Count>0){Control old=page.Controls[0];page.Controls.Remove(old);old.Dispose();}
                BuildHome();LayoutPage();viewport.AutoScrollPosition=new Point(0,scroll);
            }
        }
        private void BuildPerformance()
        {
            page.Controls.Add(Intro("RENDIMIENTO","Configuración de rendimiento","Energía y apariencia, reunidas en un solo espacio. Herramientas pendientes de integración."));
            TileGrid grid=Grid(2);
            grid.Controls.Add(Tool("power","Plan de energía","Consultar planes disponibles y solicitar cambios compatibles con el equipo."));
            grid.Controls.Add(Tool("display","Efectos visuales","Elegir una apariencia equilibrada entre claridad, animaciones y legibilidad."));
            grid.Controls.Add(Tool("display","Transparencia","Consultar y ajustar la transparencia de las superficies de Windows."));page.Controls.Add(grid);
        }
        private void BuildApps()
        {
            page.Controls.Add(Intro("APLICACIONES","Cada aplicación, en contexto.","Distingue el inicio automático, los permisos de segundo plano y los procesos activos."));
            TileGrid grid=Grid(2);
            grid.Controls.Add(Tool("Aplicaciones","Programas de inicio","Revisar las entradas de inicio y sus estados, conservando sus originales."));
            grid.Controls.Add(Tool("Aplicaciones","Permisos de segundo plano","Mostrar capacidades y evidencia según edición de Windows y tipo de aplicación."));
            grid.Controls.Add(Tool("cpu","Procesos activos","Explorar una instantánea de procesos. Cerrar un proceso no cambia sus permisos."));page.Controls.Add(grid);
        }
        private void BuildMaintenance()
        {
            page.Controls.Add(Intro("MANTENIMIENTO","Primero, entender el estado.","Diagnóstico antes de actuar. Los análisis y las operaciones se conectarán en una etapa posterior."));
            TileGrid grid=Grid(2);
            grid.Controls.Add(Tool("Mantenimiento","Limpieza","Espacio reservado para el análisis de temporales y la revisión de limpieza en Windows."));
            grid.Controls.Add(Tool("disk","Diagnóstico SSD / HDD","Espacio reservado para unidades, estado de Windows e información de TRIM."));page.Controls.Add(grid);
        }
        private void BuildRecovery()
        {
            page.Controls.Add(Intro("RESTAURACIÓN","Volver, con claridad.","Accesos previstos a la recuperación existente. Este prototipo no abre ni interpreta respaldos."));
            TileGrid grid=Grid(2);
            grid.Controls.Add(Tool("Restauración","Ajustes generales","Energía, efectos visuales y transparencia conservan su restauración existente."));
            grid.Controls.Add(Tool("Restauración","Inicio y permisos","Las recuperaciones de inicio y segundo plano permanecerán en su ámbito correspondiente."));
            grid.Controls.Add(Tool("Restauración","Configuración TRIM","La restauración de TRIM seguirá separada del mantenimiento de discos."));
            grid.Controls.Add(new Tile("Acerca de","Respaldos existentes","No se han consultado. No hay datos de respaldo simulados ni originales que restaurar en esta vista.",normal,bold,metric,null,false,scale));page.Controls.Add(grid);
        }
        private void BuildAbout()
        {
            page.Controls.Add(Intro("ACERCA DE","JUNO, una nueva etapa.","Herramientas para comprender y gestionar Windows con decisiones explícitas."));
            TileGrid grid=Grid(2);
            grid.Controls.Add(new Tile("Acerca de","JUNO "+PreviewVersion,"Dashboard de solo lectura para Windows 10 y Windows 11. PowerShell 5.1, Windows Forms y .NET Framework.",normal,bold,metric,null,false,scale));
            grid.Controls.Add(new Tile("Acerca de","Diseñado para integrar","La versión estable v0.8.1 conserva su entrada y sus módulos. Las herramientas de optimización siguen desconectadas.",normal,bold,metric,null,false,scale));page.Controls.Add(grid);
            VStack project=new VStack{Gap=(int)(12*scale)};project.Controls.Add(TextLabel("PROYECTO ABIERTO",small,Colors.Amber));
            LinkLabel link=new LinkLabel{Text="github.com/lucianoaromi/Juno ↗",AutoSize=true,Font=bold,LinkColor=Colors.Amber,ActiveLinkColor=Colors.Text,VisitedLinkColor=Colors.Amber,Name="GitHub",AccessibleDescription=RepositoryUrl};
            link.LinkClicked+=delegate{try{Process.Start(new ProcessStartInfo(RepositoryUrl){UseShellExecute=true});}catch(Exception){status.Text="No se pudo abrir el navegador. Enlace: "+RepositoryUrl;}};
            project.Controls.Add(link);project.Controls.Add(TextLabel("Interfaz aprobada · Etapa 2\nLa integración de herramientas corresponde a una etapa posterior.",normal,Colors.Muted));page.Controls.Add(project);
        }
        protected override void OnLayout(LayoutEventArgs e)
        {
            if(sidebar!=null&&!layingOut){
                layingOut=true;
                try{
                    int side=(int)(230*scale),top=(int)(72*scale),bottom=(int)(46*scale);
                    sidebar.SetBounds(0,0,side,ClientSize.Height);
                    LayoutSidebar();
                    header.SetBounds(side,0,Math.Max(1,ClientSize.Width-side),top);
                    main.SetBounds(side,top,Math.Max(1,ClientSize.Width-side),Math.Max(1,ClientSize.Height-top-bottom));
                    footer.SetBounds(side,ClientSize.Height-bottom,Math.Max(1,ClientSize.Width-side),bottom);
                    viewport.Dock=DockStyle.Fill;
                    Label badge=header.Controls["InformationBadge"] as Label;
                    bool compact=header.Width<640*scale;
                    if(breadcrumb!=null)breadcrumb.SetBounds((int)(32*scale),compact?(int)(13*scale):(int)(26*scale),Math.Max(1,header.Width-(int)((compact?64:320)*scale)),(int)(20*scale));
                    if(badge!=null){badge.SetBounds(compact?(int)(32*scale):header.Width-(int)(280*scale),compact?(int)(40*scale):(int)(26*scale),Math.Max(1,(int)((compact?header.Width/scale-64:248)*scale)),(int)(20*scale));badge.TextAlign=compact?ContentAlignment.MiddleLeft:ContentAlignment.MiddleRight;}
                    if(status!=null){status.SetBounds((int)(32*scale),(int)(12*scale),Math.Max(1,footer.Width-(int)(64*scale)),(int)(24*scale));status.AutoSize=false;status.AutoEllipsis=true;}
                    LayoutPage();
                }finally{layingOut=false;}
            }
            base.OnLayout(e);
        }
        private void LayoutSidebar()
        {
            int offset=sidebar.AutoScrollPosition.Y;
            Control icon=sidebar.Controls["BrandIcon"];
            if(icon==null||navigation.Count!=Sections.Length||sidebar.Controls["NavNotice"]==null)return;
            icon.SetBounds((int)(24*scale),(int)(29*scale)+offset,(int)(48*scale),(int)(48*scale));
            sidebar.Controls["BrandName"].Location=new Point((int)(82*scale),(int)(26*scale)+offset);
            sidebar.Controls["BrandVersion"].Location=new Point((int)(84*scale),(int)(68*scale)+offset);
            sidebar.Controls["NavGroup"].Location=new Point((int)(26*scale),(int)(116*scale)+offset);
            int y=149;
            foreach(string section in Sections){PreviewButton button=navigation[section];button.SetBounds((int)(14*scale),(int)(y*scale)+offset,Math.Max(1,sidebar.ClientSize.Width-(int)(28*scale)),(int)(48*scale));y+=56;}
            Label notice=(Label)sidebar.Controls["NavNotice"];
            if(notice!=null){notice.MaximumSize=new Size((int)(180*scale),0);notice.Location=new Point((int)(26*scale),(int)(510*scale)+offset);}
            sidebar.AutoScrollMinSize=new Size(0,(int)(575*scale));
        }
        private void LayoutPage()
        {
            if(page==null||viewport==null)return;
            int pad=(int)(32*scale);
            // Reserva estable para la barra: evita oscilaciones de ancho al aparecer el scroll.
            int width=Math.Max(1,viewport.ClientSize.Width-pad*2-SystemInformation.VerticalScrollBarWidth);
            page.SuspendLayout();
            foreach(Control c in page.Controls){
                TileGrid grid=c as TileGrid;if(grid!=null)grid.UiScale=scale;
                Surface hero=c as Surface;
                if(hero!=null&&hero.Tag is VStack){VStack content=(VStack)hero.Tag;foreach(Control child in content.Controls){Label l=child as Label;if(l!=null)l.MaximumSize=new Size(Math.Max(1,width-hero.Padding.Horizontal),0);}hero.Height=content.GetPreferredSize(new Size(Math.Max(1,width-hero.Padding.Horizontal),0)).Height+hero.Padding.Vertical;}
                VStack stack=c as VStack;if(stack!=null)foreach(Control child in stack.Controls){Label l=child as Label;if(l!=null)l.MaximumSize=new Size(width,0);}
            }
            int height=page.GetPreferredSize(new Size(width,0)).Height;
            page.SetBounds(pad,pad+viewport.AutoScrollPosition.Y,width,height);page.ResumeLayout(true);
            viewport.AutoScrollMinSize=new Size(0,height+pad*2);
        }
        protected override void OnShown(EventArgs e)
        {
            Rectangle area=Screen.FromControl(this).WorkingArea;
            MinimumSize=new Size(Math.Min(MinimumSize.Width,Math.Max(1,area.Width-24)),Math.Min(MinimumSize.Height,Math.Max(1,area.Height-24)));
            Size=new Size(Math.Min(Width,area.Width-24),Math.Min(Height,area.Height-24));
            Location=new Point(area.Left+(area.Width-Width)/2,area.Top+(area.Height-Height)/2);
            base.OnShown(e);LayoutPage();if(!dashboard.HasRequested)RefreshInformation();
        }
        protected override void Dispose(bool disposing)
        {
            if(disposing&&!ResourcesReleased){dashboardTimer.Stop();dashboardTimer.Dispose();dashboard.Dispose();base.Dispose(true);foreach(IDisposable asset in assets)asset.Dispose();foreach(Font font in fonts)font.Dispose();ResourcesReleased=true;return;}
            base.Dispose(disposing);
        }
    }
}
