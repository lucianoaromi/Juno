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
            using(Form dialog=new Form())
            using(Font font=new Font("Segoe UI",10)){
                dialog.Text=title;dialog.StartPosition=FormStartPosition.CenterParent;
                dialog.BackColor=Colors.Canvas;dialog.ForeColor=Colors.Text;dialog.Font=font;
                dialog.Size=new Size(760,540);dialog.MinimumSize=new Size(480,360);
                dialog.MinimizeBox=false;dialog.MaximizeBox=false;dialog.ShowInTaskbar=false;
                dialog.Padding=new Padding(16);
                TextBox text=new TextBox{Multiline=true,ReadOnly=true,WordWrap=true,ScrollBars=ScrollBars.Vertical,Dock=DockStyle.Fill,Text=message,BackColor=Colors.Card,ForeColor=Colors.Text,BorderStyle=BorderStyle.FixedSingle};
                FlowLayoutPanel actions=new FlowLayoutPanel{Dock=DockStyle.Bottom,Height=54,FlowDirection=FlowDirection.RightToLeft,Padding=new Padding(0,10,0,0)};
                PreviewButton cancel=new PreviewButton{Text="Cancelar",Width=140,Height=36,Font=font,DialogResult=DialogResult.Cancel};
                PreviewButton accept=new PreviewButton{Text="Autorizar",Width=140,Height=36,Font=font,Accent=true,DialogResult=DialogResult.OK};
                actions.Controls.Add(cancel);actions.Controls.Add(accept);dialog.Controls.Add(text);dialog.Controls.Add(actions);
                dialog.AcceptButton=cancel;dialog.CancelButton=cancel;dialog.ActiveControl=cancel;
                dialog.Shown+=delegate{Rectangle area=Screen.FromControl(dialog).WorkingArea;dialog.MinimumSize=new Size(Math.Min(dialog.MinimumSize.Width,area.Width-24),Math.Min(dialog.MinimumSize.Height,area.Height-24));dialog.Size=new Size(Math.Min(dialog.Width,area.Width-24),Math.Min(dialog.Height,area.Height-24));cancel.Focus();};
                return dialog.ShowDialog(owner)==DialogResult.OK;
            }
        }
    }
}
