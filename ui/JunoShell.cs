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
    public sealed class PowerPlanSelectionDialog : IPowerPlanSelection
    {
        private readonly IWin32Window owner;
        public PowerPlanSelectionDialog(IWin32Window parent){owner=parent;}
        public string Choose(PowerPlanChoice[] choices)
        {
            using(Form dialog=new Form())using(Font font=new Font("Segoe UI",10)){
                dialog.Name="PowerSelection";dialog.Text="JUNO · Elegir plan existente";dialog.BackColor=Colors.Canvas;dialog.ForeColor=Colors.Text;dialog.Font=font;
                dialog.StartPosition=FormStartPosition.CenterParent;dialog.Size=new Size(540,330);dialog.MinimumSize=new Size(400,280);dialog.ShowInTaskbar=false;dialog.MinimizeBox=false;dialog.MaximizeBox=false;dialog.Padding=new Padding(16);
                Label note=new Label{Text="Elegí el plan que querés utilizar.",Dock=DockStyle.Top,Height=34,ForeColor=Colors.Text};
                ListBox list=new ListBox{Name="PowerPlanList",Dock=DockStyle.Fill,BackColor=Colors.Card,ForeColor=Colors.Text,BorderStyle=BorderStyle.FixedSingle,IntegralHeight=false};
                foreach(PowerPlanChoice choice in choices){int count=0;foreach(PowerPlanChoice other in choices)if(other.Name==choice.Name)count++;int index=0;for(int i=0;i<list.Items.Count;i++)if(choices[i].Name==choice.Name)index++;list.Items.Add(choice.Name+(count>1?" · opción "+(index+1):""));}
                TextBox details=new TextBox{Name="PowerPlanDetails",Dock=DockStyle.Bottom,Height=92,Visible=false,Multiline=true,ReadOnly=true,ScrollBars=ScrollBars.Vertical,BackColor=Colors.Card,ForeColor=Colors.Muted,Text="Seleccioná un plan para ver su identificador."};
                LinkLabel toggle=new LinkLabel{Name="SelectionDetails",Text="Ver detalles",Dock=DockStyle.Bottom,Height=28,LinkColor=Colors.Muted};
                toggle.Click+=delegate{details.Visible=!details.Visible;toggle.Text=details.Visible?"Ocultar detalles":"Ver detalles";};
                FlowLayoutPanel actions=new FlowLayoutPanel{Dock=DockStyle.Bottom,Height=50,FlowDirection=FlowDirection.RightToLeft,Padding=new Padding(0,10,0,0)};
                PreviewButton cancel=new PreviewButton{Text="Cancelar",Secondary=true,Width=130,Height=36,Font=font,DialogResult=DialogResult.Cancel};
                PreviewButton accept=new PreviewButton{Text="Elegir plan",Secondary=true,Width=145,Height=36,Font=font,Enabled=false,DialogResult=DialogResult.OK};
                list.SelectedIndex=-1;list.SelectedIndexChanged+=delegate{accept.Enabled=list.SelectedIndex>=0;if(accept.Enabled){PowerPlanChoice choice=choices[list.SelectedIndex];details.Text="Detalles\r\nNombre: "+choice.Name+"\r\nIdentificador: "+choice.Guid+"\r\nLa elección autoriza activar este GUID; no modificar sus ajustes.";}};
                actions.Controls.Add(cancel);actions.Controls.Add(accept);dialog.Controls.Add(list);dialog.Controls.Add(details);dialog.Controls.Add(toggle);dialog.Controls.Add(actions);dialog.Controls.Add(note);dialog.AcceptButton=cancel;dialog.CancelButton=cancel;dialog.ActiveControl=cancel;
                dialog.Shown+=delegate{Rectangle area=Screen.FromControl(dialog).WorkingArea;dialog.MinimumSize=new Size(Math.Min(dialog.MinimumSize.Width,area.Width-24),Math.Min(dialog.MinimumSize.Height,area.Height-24));dialog.Size=new Size(Math.Min(dialog.Width,area.Width-24),Math.Min(dialog.Height,area.Height-24));cancel.Focus();};
                return dialog.ShowDialog(owner)==DialogResult.OK&&list.SelectedIndex>=0?choices[list.SelectedIndex].Guid:null;
            }
        }
    }
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
        public bool Secondary;
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
            bool secondary=Secondary&&!Accent&&!Selected;
            Color secondaryBackground=hover&&Enabled?Color.FromArgb(40,49,63):Color.FromArgb(30,37,49);
            Color bg=Selected?Colors.Selected:(Accent?Colors.Amber:(secondary?secondaryBackground:(hover&&Enabled?Color.FromArgb(33,41,54):BackColor)));
            Color fg=Selected?Colors.Amber:(Accent?Colors.Canvas:(Enabled?Colors.Text:Colors.Muted));
            if(!Enabled&&Accent){bg=Colors.Selected;fg=Colors.Muted;}
            e.Graphics.Clear(BackColor);e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
            using(GraphicsPath path=Shapes.Round(new RectangleF(.5f,.5f,Width-1,Height-1),8*s))
            using(SolidBrush brush=new SolidBrush(bg)) {
                e.Graphics.FillPath(brush,path);
                if(secondary){
                    Color border=Enabled?Color.FromArgb(92,108,129):Colors.Border;
                    using(Pen pen=new Pen(border)){e.Graphics.DrawPath(pen,path);}
                }
            }
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

    internal class ToolActions : Panel
    {
        private readonly float scale;
        public ToolActions(float factor){scale=factor;}
        public override Size GetPreferredSize(Size proposedSize){return new Size(proposedSize.Width,(int)(36*scale)*(Controls.Count>1&&proposedSize.Width<300*scale?Controls.Count:1));}
        protected override void OnLayout(LayoutEventArgs e)
        {
            bool vertical=Controls.Count>1&&ClientSize.Width<300*scale;int count=Math.Max(1,Controls.Count),gap=(int)(8*scale);
            for(int i=0;i<Controls.Count;i++)Controls[i].SetBounds(vertical?0:i*(ClientSize.Width+gap)/count,vertical?i*(int)(36*scale):0,vertical?ClientSize.Width:(ClientSize.Width-gap*(count-1))/count,(int)(32*scale));
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
            if(!String.IsNullOrEmpty(text))stack.Controls.Add(detail);
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
        internal void AddContent(Control control){stack.Controls.Add(control);}
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
        public const string PreviewVersion="0.9 · Etapa 3D";
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
        private readonly TransparencyController transparency;
        private readonly ITransparencyConfirmation transparencyConfirmation;
        private readonly IColorsSettingsLauncher colorsSettings;
        private readonly Timer transparencyTimer;
        private bool reviewingTransparency;
        public TransparencyController Transparency {get{return transparency;}}
        private readonly PowerController power;
        private readonly IPowerPlansLauncher powerPlans;
        private readonly IPowerPlanSelection powerSelection;
        private readonly Timer powerTimer;
        private bool reviewingPower;
        public PowerController Power {get{return power;}}
        private readonly VisualController visual;
        private readonly Timer visualTimer;
        private bool reviewingVisual;
        private VisualAction visualMode=VisualAction.Quality;
        private readonly IVisualSettingsLauncher visualSettings;
        private string visualWindowsFailure,visualWindowsDiagnostic;
        public VisualController Visual {get{return visual;}}
        private readonly StartupController startup;
        private readonly IStartupSettingsLauncher startupSettings;
        private readonly Timer startupTimer;
        private bool reviewingStartup;
        private bool requestingTool;
        public StartupController Startup {get{return startup;}}

        public ShellForm(string assetRoot):this(assetRoot,new DashboardController(new UnavailableDashboardQuery())){}
        public ShellForm(string assetRoot,DashboardController controller):this(assetRoot,controller,new TransparencyController(new UnavailableTransparencyService()),null){}
        public ShellForm(string assetRoot,DashboardController controller,TransparencyController integration,ITransparencyConfirmation confirmation)
            :this(assetRoot,controller,integration,confirmation,new PowerController(new UnavailablePowerService()),null){}
        public ShellForm(string assetRoot,DashboardController controller,TransparencyController integration,ITransparencyConfirmation confirmation,PowerController energy,IPowerPlansLauncher plans)
            :this(assetRoot,controller,integration,confirmation,energy,plans,null){}
        public ShellForm(string assetRoot,DashboardController controller,TransparencyController integration,ITransparencyConfirmation confirmation,PowerController energy,IPowerPlansLauncher plans,IPowerPlanSelection selection)
            :this(assetRoot,controller,integration,confirmation,energy,plans,selection,new VisualController(new UnavailableVisualService())){}
        public ShellForm(string assetRoot,DashboardController controller,TransparencyController integration,ITransparencyConfirmation confirmation,PowerController energy,IPowerPlansLauncher plans,IPowerPlanSelection selection,VisualController effects)
            :this(assetRoot,controller,integration,confirmation,energy,plans,selection,effects,null){}
        public ShellForm(string assetRoot,DashboardController controller,TransparencyController integration,ITransparencyConfirmation confirmation,PowerController energy,IPowerPlansLauncher plans,IPowerPlanSelection selection,VisualController effects,IVisualSettingsLauncher settings)
            :this(assetRoot,controller,integration,confirmation,energy,plans,selection,effects,settings,new StartupController(new UnavailableStartupService()),null){}
        public ShellForm(string assetRoot,DashboardController controller,TransparencyController integration,ITransparencyConfirmation confirmation,PowerController energy,IPowerPlansLauncher plans,IPowerPlanSelection selection,VisualController effects,IVisualSettingsLauncher settings,StartupController launchItems,IStartupSettingsLauncher launchSettings)
            :this(assetRoot,controller,integration,confirmation,energy,plans,selection,effects,settings,launchItems,launchSettings,null){}
        public ShellForm(string assetRoot,DashboardController controller,TransparencyController integration,ITransparencyConfirmation confirmation,PowerController energy,IPowerPlansLauncher plans,IPowerPlanSelection selection,VisualController effects,IVisualSettingsLauncher settings,StartupController launchItems,IStartupSettingsLauncher launchSettings,IColorsSettingsLauncher colors)
        {
            if(controller==null)throw new ArgumentNullException("controller");dashboard=controller;
            if(integration==null)throw new ArgumentNullException("integration");transparency=integration;
            transparencyConfirmation=confirmation??new TransparencyConfirmation(this);
            colorsSettings=colors??new WindowsColorsSettingsLauncher();
            if(energy==null)throw new ArgumentNullException("energy");power=energy;
            powerPlans=plans??new WindowsPowerPlansLauncher();
            powerSelection=selection??new PowerPlanSelectionDialog(this);
            if(effects==null)throw new ArgumentNullException("effects");visual=effects;
            visualSettings=settings??new WindowsVisualSettingsLauncher(assetRoot);
            if(launchItems==null)throw new ArgumentNullException("launchItems");startup=launchItems;
            startupSettings=launchSettings??new WindowsStartupSettingsLauncher();
            startupTimer=new Timer();startupTimer.Interval=100;
            startupTimer.Tick+=delegate{
                TransparencyReview review=startup.PendingReview;
                if(review!=null&&!reviewingStartup){
                    bool allowed=false;reviewingStartup=true;startupTimer.Stop();
                    try{allowed=transparencyConfirmation.Confirm("JUNO · Revisar recuperación de inicio",review.Message);}
                    finally{review.Answer(allowed);reviewingStartup=false;if(startup.IsBusy)startupTimer.Start();}
                }
                if(startup.Poll())RefreshTransparencyView();
                if(!startup.IsBusy)startupTimer.Stop();
            };
            visualTimer=new Timer();visualTimer.Interval=100;
            visualTimer.Tick+=delegate{
                TransparencyReview review=visual.PendingReview;
                if(review!=null&&!reviewingVisual){
                    bool allowed=false;reviewingVisual=true;visualTimer.Stop();
                    try{allowed=transparencyConfirmation.Confirm("JUNO · Revisar recuperación visual",review.Message);}
                    finally{review.Answer(allowed);reviewingVisual=false;if(visual.IsBusy)visualTimer.Start();}
                }
                if(visual.Poll())RefreshTransparencyView();
                if(!visual.IsBusy)visualTimer.Stop();
            };
            powerTimer=new Timer();powerTimer.Interval=100;
            powerTimer.Tick+=delegate{
                TransparencyReview review=power.PendingReview;
                if(review!=null&&!reviewingPower){
                    bool allowed=false;reviewingPower=true;powerTimer.Stop();
                    try{allowed=transparencyConfirmation.Confirm("JUNO · Revisar recuperación de energía",review.Message);}
                    finally{review.Answer(allowed);reviewingPower=false;if(power.IsBusy)powerTimer.Start();}
                }
                if(power.Poll())RefreshTransparencyView();
                if(!power.IsBusy)powerTimer.Stop();
            };
            transparencyTimer=new Timer();transparencyTimer.Interval=100;
            transparencyTimer.Tick+=delegate{
                TransparencyReview review=transparency.PendingReview;
                if(review!=null&&!reviewingTransparency){
                    bool allowed=false;reviewingTransparency=true;transparencyTimer.Stop();
                    try{allowed=transparencyConfirmation.Confirm("JUNO · Revisar recuperación",review.Message);}
                    finally{review.Answer(allowed);reviewingTransparency=false;if(transparency.IsBusy)transparencyTimer.Start();}
                }
                if(transparency.Poll())RefreshTransparencyView();
                if(!transparency.IsBusy)transparencyTimer.Stop();
            };
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
            Label notice=Tile.MakeLabel("VISTA PREVIA\nInicio, energía y apariencia",small,Colors.Muted);notice.Name="NavNotice";sidebar.Controls.Add(notice);
        }
        private void BuildHeader()
        {
            breadcrumb=Tile.MakeLabel("ESPACIO DE TRABAJO  /  Inicio",small,Colors.Muted);breadcrumb.AutoSize=false;breadcrumb.AutoEllipsis=true;header.Controls.Add(breadcrumb);
            Label badge=Tile.MakeLabel("●  SOLO LECTURA",OwnFont(8,FontStyle.Bold),Colors.Amber);badge.Name="InformationBadge";badge.AutoSize=false;badge.TextAlign=ContentAlignment.MiddleRight;header.Controls.Add(badge);
            header.Paint+=delegate(object sender,PaintEventArgs e){using(Pen pen=new Pen(Colors.Border)){e.Graphics.DrawLine(pen,0,header.Height-1,header.Width,header.Height-1);}};
        }
        private void BuildFooter()
        {
            status=Tile.MakeLabel(ToolsStatus,small,Colors.Muted);status.Name="PreviewStatus";footer.Controls.Add(status);
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
            status.Text=ToolsStatus;
            header.Controls["InformationBadge"].Text=section=="Inicio"?"●  LECTURA DEL SISTEMA":section=="Rendimiento"?"●  AJUSTES DE RENDIMIENTO":section=="Aplicaciones"?"●  PROGRAMAS DE INICIO":"●  HERRAMIENTAS SIN CONECTAR";
            switch(section){
                case "Inicio":BuildHome();break;
                case "Rendimiento":BuildPerformance();break;
                case "Aplicaciones":BuildApps();break;
                case "Mantenimiento":BuildMaintenance();break;
                case "Restauración":BuildRecovery();break;
                case "Acerca de":BuildAbout();break;
            }
            LayoutPage();
            if(section=="Rendimiento"&&Visible&&!transparency.HasRequested)RequestTransparency(TransparencyAction.Read);
            if(section=="Rendimiento"&&Visible&&power.IsConfigured&&!power.HasRequested&&!transparency.IsBusy)RequestPower(PowerAction.Read);
            if(section=="Rendimiento"&&Visible&&visual.IsConfigured&&!visual.HasRequested&&!transparency.IsBusy&&!power.IsBusy)RequestVisual(VisualAction.Read);
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
            page.Controls.Add(Intro("RENDIMIENTO","Configuración de rendimiento","Elegí qué ajustar. Cada herramienta conserva su configuración anterior para restaurarla."));
            TileGrid grid=Grid(2);
            BuildPower(grid);
            BuildVisual(grid);
            BuildTransparency(grid);page.Controls.Add(grid);
        }
        private void BuildApps()
        {
            TileGrid grid=Grid(2);
            BuildStartup();
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
        private bool StartupBlocked {get{return requestingTool||startup.IsBusy||transparency.IsBusy||power.IsBusy||visual.IsBusy||reviewingStartup||reviewingTransparency||reviewingPower||reviewingVisual;}}
        private void BuildStartup()
        {
            page.Controls.Add(new StartupSettingsSection(scale,normal,bold,!StartupBlocked,OpenStartupWindows));
        }
        public bool RequestStartup(StartupAction action,string id)
        {
            if(action==StartupAction.Enable||action==StartupAction.Disable)return false;
            if(StartupBlocked)return false;
            bool started;requestingTool=true;try{started=startup.Start(action,id,transparencyConfirmation);}finally{requestingTool=false;}
            RefreshTransparencyView();if(started)startupTimer.Start();return started;
        }
        private void RefreshStartupView()
        {
            if(IsDisposed||Disposing)return;
            if(SelectedSection=="Restauración"){
                int scroll=-viewport.AutoScrollPosition.Y;
                while(page.Controls.Count>0){Control old=page.Controls[0];page.Controls.Remove(old);old.Dispose();}
                BuildRecovery();LayoutPage();viewport.AutoScrollPosition=new Point(0,scroll);
            }
            status.Text=ToolsStatus;
        }
        private void OpenStartupWindows()
        {
            if(StartupBlocked)return;
            try{startupSettings.Open();}
            catch(Exception){status.Text="No se pudo abrir la configuración de inicio de Windows.";}
        }
        private void BuildRecovery()
        {
            page.Controls.Add(Intro("RESTAURACIÓN","Volver, con claridad.","La restauración general aún no está integrada. Recuperá inicio aquí y los ajustes de rendimiento desde su tarjeta."));
            TileGrid grid=Grid(2);
            grid.Controls.Add(Tool("Restauración","Ajustes generales","Restaurá energía, transparencia o efectos visuales desde su tarjeta en Rendimiento."));
            Tile recovery=new Tile("startup-recovery","Programas de inicio","Recuperá los cambios de inicio guardados por JUNO.",normal,bold,metric,null,false,scale);
            recovery.AddContent(Tile.MakeLabel(startup.HasRequested?startup.Status:"Comprobá si hay cambios anteriores para restaurar.",small,Colors.Muted));
            var read=ToolButton("StartupRecoveryRead","Comprobar respaldos",false,startup.IsConfigured&&!StartupBlocked);read.Click+=delegate{RequestStartup(StartupAction.Read,null);};recovery.AddContent(read);
            if(startup.Snapshot.CanRestore){var restore=ToolButton("StartupRestore","Restaurar cambios",false,!StartupBlocked);restore.Click+=delegate{RequestStartup(StartupAction.Restore,null);};recovery.AddContent(restore);}
            grid.Controls.Add(recovery);
            grid.Controls.Add(Tool("Restauración","Configuración TRIM","La restauración de TRIM seguirá separada del mantenimiento de discos."));
            grid.Controls.Add(new Tile("Acerca de","Respaldos existentes","Esta sección no ofrece recuperación general. La tarjeta Transparencia consulta y conserva sus originales mediante el almacén estable.",normal,bold,metric,null,false,scale));page.Controls.Add(grid);
        }
        private void BuildAbout()
        {
            page.Controls.Add(Intro("ACERCA DE","JUNO, una nueva etapa.","Herramientas para comprender y gestionar Windows con decisiones explícitas."));
            TileGrid grid=Grid(2);
            grid.Controls.Add(new Tile("Acerca de","JUNO "+PreviewVersion,"Dashboard de solo lectura para Windows 10 y Windows 11. PowerShell 5.1, Windows Forms y .NET Framework.",normal,bold,metric,null,false,scale));
            grid.Controls.Add(new Tile("Acerca de","Diseñado para integrar","Energía, transparencia, efectos visuales e inicio utilizan sus motores estables. Las herramientas pendientes se muestran sin conectar.",normal,bold,metric,null,false,scale));page.Controls.Add(grid);
            VStack project=new VStack{Gap=(int)(12*scale)};project.Controls.Add(TextLabel("PROYECTO ABIERTO",small,Colors.Amber));
            LinkLabel link=new LinkLabel{Text="github.com/lucianoaromi/Juno ↗",AutoSize=true,Font=bold,LinkColor=Colors.Amber,ActiveLinkColor=Colors.Text,VisitedLinkColor=Colors.Amber,Name="GitHub",AccessibleDescription=RepositoryUrl};
            link.LinkClicked+=delegate{try{Process.Start(new ProcessStartInfo(RepositoryUrl){UseShellExecute=true});}catch(Exception){status.Text="No se pudo abrir el navegador. Enlace: "+RepositoryUrl;}};
            project.Controls.Add(link);project.Controls.Add(TextLabel("Integración de inicio · Etapa 3D\nLas herramientas solicitan confirmación antes de cambiar ajustes.",normal,Colors.Muted));page.Controls.Add(project);
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

        public bool RequestTransparency(TransparencyAction action)
        {
            if(requestingTool||startup.IsBusy||reviewingStartup)return false;
            if(power.IsBusy||reviewingPower||visual.IsBusy||reviewingVisual)return false;
            bool started;requestingTool=true;try{started=transparency.Start(action,transparencyConfirmation);}finally{requestingTool=false;}
            RefreshTransparencyView();
            if(started)transparencyTimer.Start();
            return started;
        }
        private void BuildTransparency(TileGrid grid)
        {
            TransparencyResult value=transparency.Snapshot;
            Tile tile=new Tile("transparency","Transparencia","",normal,bold,metric,TransparencyController.StateText(value.State),false,scale);
            Label state=Tile.MakeLabel(ToolPresentation.TransparencyMessage(transparency),normal,Colors.Muted);state.Name="TransparencyState";tile.AddContent(state);
            if(value.State=="Enabled"||value.State=="Disabled"){
                bool enable=value.State=="Disabled";
                PreviewButton main=ToolButton(enable?"TransparencyEnable":"TransparencyDisable",enable?"Activar transparencia":"Desactivar transparencia",value.CanChange,!visual.IsBusy&&!power.IsBusy&&transparency.CanStart(enable?TransparencyAction.Enable:TransparencyAction.Disable));
                main.Click+=delegate{RequestTransparency(enable?TransparencyAction.Enable:TransparencyAction.Disable);};tile.AddContent(main);
            }else{
                PreviewButton read=ToolButton("TransparencyRead","Volver a consultar",false,!visual.IsBusy&&!power.IsBusy&&transparency.CanStart(TransparencyAction.Read));
                read.Click+=delegate{RequestTransparency(TransparencyAction.Read);};tile.AddContent(read);
            }
            ToolActions row=new ToolActions(scale);
            if(value.CanRestore){PreviewButton restore=ToolButton("TransparencyRestore","Restaurar anterior",false,!visual.IsBusy&&!power.IsBusy&&transparency.CanStart(TransparencyAction.Restore));restore.Click+=delegate{RequestTransparency(TransparencyAction.Restore);};row.Controls.Add(restore);}
            PreviewButton windows=ToolButton("TransparencyWindows","Configurar en Windows",false,!StartupBlocked);windows.Click+=delegate{OpenTransparencyWindows();};row.Controls.Add(windows);tile.AddContent(row);grid.Controls.Add(tile);
        }
        private PreviewButton ToolButton(string name,string text,bool accent,bool enabled)
        {return new PreviewButton{Name=name,Text=text,Font=normal,Accent=accent,Secondary=!accent,Height=(int)(44*scale),Enabled=enabled&&!startup.IsBusy&&!reviewingStartup};}
        private void RefreshTransparencyView()
        {
            if(IsDisposed||Disposing)return;
            if(SelectedSection=="Restauración")RefreshStartupView();
            if(SelectedSection=="Aplicaciones"){
                Control[] buttons=Controls.Find("StartupWindows",true);if(buttons.Length==1)buttons[0].Enabled=!StartupBlocked;
            }
            if(SelectedSection=="Rendimiento"){
                int scroll=-viewport.AutoScrollPosition.Y;
                while(page.Controls.Count>0){Control old=page.Controls[0];page.Controls.Remove(old);old.Dispose();}
                BuildPerformance();LayoutPage();viewport.AutoScrollPosition=new Point(0,scroll);
            }
            status.Text=ToolsStatus;
            // Lecturas iniciales secuenciales: ambos servicios comparten el mismo mutex.
            if(SelectedSection=="Rendimiento"&&Visible&&power.IsConfigured&&!power.HasRequested&&!transparency.IsBusy)RequestPower(PowerAction.Read);
            if(SelectedSection=="Rendimiento"&&Visible&&visual.IsConfigured&&!visual.HasRequested&&!transparency.IsBusy&&!power.IsBusy)RequestVisual(VisualAction.Read);
        }
        private string ToolsStatus {get{return startup.IsBusy?"Programas de inicio · "+startup.Status:visual.IsBusy?"Efectos visuales · "+visual.Status:power.IsBusy?"Energía · "+power.Status:transparency.IsBusy?"Transparencia · "+transparency.Status:"Dashboard de solo lectura · Energía, efectos visuales, transparencia e inicio integrados";}}
        public bool RequestPower(PowerAction action)
        {
            if(requestingTool||startup.IsBusy||reviewingStartup)return false;
            if(transparency.IsBusy||reviewingTransparency||visual.IsBusy||reviewingVisual)return false;
            bool started;requestingTool=true;try{started=power.Start(action,transparencyConfirmation,powerSelection);}finally{requestingTool=false;}
            RefreshTransparencyView();
            if(started)powerTimer.Start();
            return started;
        }
        private void BuildPower(TileGrid grid)
        {
            PowerResult value=power.Snapshot;
            string reading=System.Text.RegularExpressions.Regex.Replace(value.ActiveName??"Estado desconocido",@"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}","Plan actual");
            Tile tile=new Tile("power","Plan de energía","",normal,bold,metric,reading,false,scale);
            Label state=Tile.MakeLabel(ToolPresentation.PowerMessage(power),normal,Colors.Muted);state.Name="PowerState";tile.AddContent(state);
            bool active=value.HighActive||value.SelectionActive;
            if(active&&value.CanRestore){
                PreviewButton restore=ToolButton("PowerRestore","Restaurar plan anterior",true,!visual.IsBusy&&!transparency.IsBusy&&power.CanStart(PowerAction.Restore));
                restore.Click+=delegate{RequestPower(PowerAction.Restore);};tile.AddContent(restore);
            }else if(!active){
                PreviewButton apply=ToolButton("PowerApply",value.RequiresCreation?"Crear Alto rendimiento…":value.RequiresSelection?(power.HasRememberedSelection?"Activar plan elegido":"Elegir plan existente…"):"Activar Alto rendimiento",value.CanApply&&!value.Pending,!visual.IsBusy&&!transparency.IsBusy&&power.CanStart(PowerAction.Apply));
                apply.Click+=delegate{RequestPower(PowerAction.Apply);};tile.AddContent(apply);
            }
            ToolActions row=new ToolActions(scale);
            if(!active&&value.CanRestore){PreviewButton restore=ToolButton("PowerRestore","Restaurar anterior",false,!visual.IsBusy&&!transparency.IsBusy&&power.CanStart(PowerAction.Restore));restore.Click+=delegate{RequestPower(PowerAction.Restore);};row.Controls.Add(restore);}
            PreviewButton windows=ToolButton("PowerWindows","Configurar en Windows",false,!StartupBlocked);windows.Click+=delegate{OpenPowerWindows();};row.Controls.Add(windows);tile.AddContent(row);grid.Controls.Add(tile);
        }
        private void OpenPowerWindows()
        {
            if(StartupBlocked)return;
            try{powerPlans.Open();}
            catch(Exception){status.Text="No se pudo abrir Opciones de energía de Windows.";}
        }
        private void OpenTransparencyWindows()
        {
            if(StartupBlocked)return;
            try{colorsSettings.Open();}
            catch(Exception){status.Text="No se pudo abrir Colores de Windows.";}
        }
        public Form CreateToolDetails(bool energy)
        {
            Form dialog=new Form{Name=energy?"PowerDetailsDialog":"TransparencyDetailsDialog",Text=energy?"JUNO · Detalles de energía":"JUNO · Detalles de transparencia",StartPosition=FormStartPosition.CenterParent,Size=new Size(640,460),MinimumSize=new Size(400,300),ShowInTaskbar=false,MinimizeBox=false,MaximizeBox=false,BackColor=Colors.Canvas,ForeColor=Colors.Text,Font=normal,Padding=new Padding(16)};
            TextBox text=new TextBox{Name="TechnicalDetails",Dock=DockStyle.Fill,Multiline=true,ReadOnly=true,ScrollBars=ScrollBars.Vertical,BackColor=Colors.Card,ForeColor=Colors.Text,Text=energy?ToolPresentation.PowerDetails(power):ToolPresentation.TransparencyDetails(transparency)};
            FlowLayoutPanel actions=new FlowLayoutPanel{Dock=DockStyle.Bottom,Height=100,FlowDirection=FlowDirection.RightToLeft,WrapContents=true,Padding=new Padding(0,10,0,0)};
            PreviewButton close=ToolButton("CloseDetails","Cerrar",false,true);close.Width=105;close.Height=34;close.DialogResult=DialogResult.Cancel;actions.Controls.Add(close);
            PreviewButton refresh=ToolButton(energy?"PowerRead":"TransparencyRead","Actualizar",false,!visual.IsBusy&&!power.IsBusy&&!transparency.IsBusy);refresh.Width=110;refresh.Height=34;refresh.DialogResult=DialogResult.Retry;actions.Controls.Add(refresh);
            if(energy){PreviewButton plans=ToolButton("PowerPlans","Planes de Windows",false,!visual.IsBusy&&!power.IsBusy&&!transparency.IsBusy);plans.Width=180;plans.Height=34;plans.Click+=delegate{if(visual.IsBusy||power.IsBusy||transparency.IsBusy)return;try{powerPlans.Open();}catch(Exception){text.AppendText("\r\nNo se pudo abrir Opciones de energía de Windows.");}};actions.Controls.Add(plans);}
            dialog.Controls.Add(text);dialog.Controls.Add(actions);dialog.AcceptButton=close;dialog.CancelButton=close;
            dialog.Shown+=delegate{text.SelectionStart=0;text.SelectionLength=0;close.Focus();};
            return dialog;
        }
        private void ShowToolDetails(bool energy)
        {
            using(Form dialog=CreateToolDetails(energy)){
                if(dialog.ShowDialog(this)==DialogResult.Retry){if(energy)RequestPower(PowerAction.Read);else RequestTransparency(TransparencyAction.Read);}
            }
        }
        public bool RequestVisual(VisualAction action)
        {
            if(requestingTool||startup.IsBusy||reviewingStartup)return false;
            if(power.IsBusy||transparency.IsBusy||reviewingPower||reviewingTransparency)return false;
            visualWindowsFailure=null;
            bool started;requestingTool=true;try{started=visual.Start(action,transparencyConfirmation);}finally{requestingTool=false;}RefreshTransparencyView();if(started)visualTimer.Start();return started;
        }
        private void BuildVisual(TileGrid grid)
        {
            VisualResult value=visual.Snapshot;
            Tile tile=new Tile("visual","Efectos visuales","",normal,bold,metric,VisualController.StateText(value.State),false,scale);
            Label state=Tile.MakeLabel(visualWindowsFailure??visual.Status,normal,Colors.Muted);state.Name="VisualState";tile.AddContent(state);
            ComboBox mode=new ComboBox{Name="VisualMode",Font=normal,DropDownStyle=ComboBoxStyle.DropDownList,DrawMode=DrawMode.OwnerDrawFixed,ItemHeight=normal.Height+4,BackColor=Colors.Card,ForeColor=Colors.Text,FlatStyle=FlatStyle.Flat,Enabled=!startup.IsBusy&&!visual.IsBusy&&!power.IsBusy&&!transparency.IsBusy&&value.CanApply,DropDownWidth=(int)(340*scale)};
            mode.DrawItem+=delegate(object sender,DrawItemEventArgs e){if(e.Index<0)return;using(SolidBrush background=new SolidBrush(Colors.Card)){e.Graphics.FillRectangle(background,e.Bounds);}TextRenderer.DrawText(e.Graphics,mode.Items[e.Index].ToString(),normal,e.Bounds,mode.Enabled?Colors.Text:Colors.Muted,TextFormatFlags.Left|TextFormatFlags.VerticalCenter|TextFormatFlags.NoPrefix);if((e.State&DrawItemState.Focus)!=0)ControlPaint.DrawFocusRectangle(e.Graphics,e.Bounds,Colors.Muted,Colors.Card);};
            mode.Items.Add("Rendimiento + letras nítidas");mode.Items.Add("Máximo rendimiento (avanzado)");mode.SelectedIndex=visualMode==VisualAction.Maximum?1:0;
            mode.AccessibleName="Modo de efectos visuales";mode.AccessibleDescription="Rendimiento + letras nítidas es la opción recomendada.";
            mode.SelectedIndexChanged+=delegate{visualMode=mode.SelectedIndex==1?VisualAction.Maximum:VisualAction.Quality;RefreshTransparencyView();};tile.AddContent(mode);
            tile.AddContent(Tile.MakeLabel(visualMode==VisualAction.Maximum?"Puede reducir la legibilidad de las letras.":"Recomendado: mantiene el suavizado de las letras.",small,Colors.Muted));
            bool current=value.State==visualMode.ToString();
            if(!current&&value.CanApply){PreviewButton apply=ToolButton("VisualApply",visualMode==VisualAction.Maximum?"Aplicar Máximo rendimiento":"Optimizar efectos visuales",!value.Pending,!power.IsBusy&&!transparency.IsBusy&&visual.CanStart(visualMode));apply.Click+=delegate{RequestVisual(visualMode);};tile.AddContent(apply);}
            else if(current&&value.CanRestore){PreviewButton restore=ToolButton("VisualRestore","Restaurar anterior",true,!power.IsBusy&&!transparency.IsBusy&&visual.CanStart(VisualAction.Restore));restore.Click+=delegate{RequestVisual(VisualAction.Restore);};tile.AddContent(restore);}
            ToolActions row=new ToolActions(scale);
            if(!current&&value.CanRestore){PreviewButton restore=ToolButton("VisualRestore","Restaurar anterior",false,!power.IsBusy&&!transparency.IsBusy&&visual.CanStart(VisualAction.Restore));restore.Click+=delegate{RequestVisual(VisualAction.Restore);};row.Controls.Add(restore);}
            PreviewButton windows=ToolButton("VisualWindows","Configurar en Windows",false,!visual.IsBusy&&!power.IsBusy&&!transparency.IsBusy);
            windows.AccessibleDescription="Abrir Efectos visuales de Windows. F5 actualiza el estado; F1 abre el diagnóstico. También disponibles en el menú contextual.";
            windows.Click+=delegate{OpenVisualWindows();};row.Controls.Add(windows);tile.AddContent(row);
            ToolTip hint=new ToolTip();hint.SetToolTip(windows,windows.AccessibleDescription);windows.Disposed+=delegate{hint.Dispose();};
            ContextMenuStrip menu=new ContextMenuStrip{BackColor=Colors.Card,ForeColor=Colors.Text};
            ToolStripMenuItem refresh=new ToolStripMenuItem("Actualizar estado"){Name="VisualRefreshMenu",ShortcutKeyDisplayString="F5",Enabled=!visual.IsBusy&&!power.IsBusy&&!transparency.IsBusy};refresh.Click+=delegate{RequestVisual(VisualAction.Read);};
            ToolStripMenuItem diagnostics=new ToolStripMenuItem("Diagnóstico"){Name="VisualDiagnosticsMenu",ShortcutKeyDisplayString="F1"};diagnostics.Click+=delegate{ShowVisualDiagnostics();};menu.Items.Add(refresh);menu.Items.Add(diagnostics);
            Action<Control> attach=null;attach=control=>{control.ContextMenuStrip=menu;foreach(Control child in control.Controls)attach(child);};attach(tile);
            tile.Disposed+=delegate{menu.Dispose();};grid.Controls.Add(tile);
        }
        private void OpenVisualWindows()
        {
            if(startup.IsBusy||reviewingStartup)return;
            if(visual.IsBusy||power.IsBusy||transparency.IsBusy||reviewingVisual||reviewingPower||reviewingTransparency)return;
            try{visualSettings.Open();visualWindowsFailure=null;}
            catch(Exception error){visualWindowsFailure="No se pudo abrir la configuración de Windows.";visualWindowsDiagnostic=error.ToString();}
            Control[] states=Controls.Find("VisualState",true);if(states.Length==1)states[0].Text=visualWindowsFailure??visual.Status;
            LayoutPage();
        }
        private void ShowVisualDiagnostics()
        {using(Form dialog=CreateVisualDetails()){if(dialog.ShowDialog(this)==DialogResult.Retry)RequestVisual(VisualAction.Read);}}
        protected override bool ProcessCmdKey(ref Message msg,Keys keyData)
        {
            Control[] cards=Controls.Find("visual",true);
            if(SelectedSection=="Rendimiento"&&cards.Length==1&&cards[0].ContainsFocus){
                if(keyData==Keys.F5){RequestVisual(VisualAction.Read);return true;}
                if(keyData==Keys.F1){ShowVisualDiagnostics();return true;}
            }
            return base.ProcessCmdKey(ref msg,keyData);
        }
        public Form CreateVisualDetails()
        {
            Form dialog=new Form{Name="VisualDetailsDialog",Text="JUNO · Detalles de efectos visuales",StartPosition=FormStartPosition.CenterParent,Size=new Size(640,460),MinimumSize=new Size(400,300),ShowInTaskbar=false,MinimizeBox=false,MaximizeBox=false,BackColor=Colors.Canvas,ForeColor=Colors.Text,Font=normal,Padding=new Padding(16)};
            TextBox text=new TextBox{Name="TechnicalDetails",Multiline=true,ReadOnly=true,ScrollBars=ScrollBars.Vertical,Dock=DockStyle.Fill,BackColor=Colors.Card,ForeColor=Colors.Text,Text=visual.Details+(String.IsNullOrEmpty(visualWindowsDiagnostic)?"":"\r\n\r\nÚltimo error al abrir Windows:\r\n"+visualWindowsDiagnostic)};
            FlowLayoutPanel actions=new FlowLayoutPanel{Dock=DockStyle.Bottom,Height=60,FlowDirection=FlowDirection.RightToLeft,Padding=new Padding(0,10,0,0)};
            PreviewButton close=ToolButton("CloseDetails","Cerrar",false,true);close.Width=105;close.Height=34;close.DialogResult=DialogResult.Cancel;
            PreviewButton refresh=ToolButton("VisualRead","Actualizar",false,!power.IsBusy&&!transparency.IsBusy&&!visual.IsBusy);refresh.Width=110;refresh.Height=34;refresh.DialogResult=DialogResult.Retry;
            actions.Controls.Add(close);actions.Controls.Add(refresh);dialog.Controls.Add(text);dialog.Controls.Add(actions);dialog.AcceptButton=close;dialog.CancelButton=close;
            dialog.Shown+=delegate{text.SelectionStart=0;text.SelectionLength=0;close.Focus();};return dialog;
        }
        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if(startup.IsWriting){startup.Poll();if(startup.IsWriting){e.Cancel=true;status.Text="Inicio en curso. Esperá la verificación antes de cerrar.";}}
            if(visual.IsWriting){visual.Poll();if(visual.IsWriting){e.Cancel=true;RefreshTransparencyView();}}
            if(power.IsWriting){power.Poll();if(power.IsWriting){e.Cancel=true;RefreshTransparencyView();}}
            if(transparency.IsWriting){
                transparency.Poll();
                if(transparency.IsWriting){e.Cancel=true;status.Text="Transparencia en curso. Espera la verificación antes de cerrar.";RefreshTransparencyView();}
            }
            base.OnFormClosing(e);
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
            if(SelectedSection=="Rendimiento"&&!transparency.HasRequested)RequestTransparency(TransparencyAction.Read);
            if(SelectedSection=="Rendimiento"&&power.IsConfigured&&!power.HasRequested&&!transparency.IsBusy)RequestPower(PowerAction.Read);
            if(SelectedSection=="Rendimiento"&&visual.IsConfigured&&!visual.HasRequested&&!transparency.IsBusy&&!power.IsBusy)RequestVisual(VisualAction.Read);
        }
        protected override void Dispose(bool disposing)
        {
            if(disposing&&!ResourcesReleased){startupTimer.Stop();startupTimer.Dispose();startup.Dispose();}
            if(disposing&&!ResourcesReleased){visualTimer.Stop();visualTimer.Dispose();visual.Dispose();powerTimer.Stop();powerTimer.Dispose();power.Dispose();transparencyTimer.Stop();transparencyTimer.Dispose();transparency.Dispose();dashboardTimer.Stop();dashboardTimer.Dispose();dashboard.Dispose();base.Dispose(true);foreach(IDisposable asset in assets)asset.Dispose();foreach(Font font in fonts)font.Dispose();ResourcesReleased=true;return;}
            base.Dispose(disposing);
        }
    }
}
