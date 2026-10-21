using System;
using System.Threading.Tasks;
namespace Juno.Preview.Testing
{
    public sealed class ControlledStartup : IStartupService
    {
        public int Calls,WriteCalls;
        public bool Disposed;
        public string LastId,LastFingerprint,LastApprovalToken;
        public bool LastConfirmed;
        public StartupAction LastAction;
        public TransparencyReview PendingReview {get;set;}
        public TaskCompletionSource<StartupResult> Completion=new TaskCompletionSource<StartupResult>();
        public Task<StartupResult> ExecuteAsync(StartupAction action,string id,string fingerprint,string approvalToken,bool confirmed)
        {Calls++;if(action!=StartupAction.Read)WriteCalls++;LastAction=action;LastId=id;LastFingerprint=fingerprint;LastApprovalToken=approvalToken;LastConfirmed=confirmed;return Completion.Task;}
        public void Complete(StartupResult value){Completion.TrySetResult(value);}
        public void Next(){Completion=new TaskCompletionSource<StartupResult>();}
        public void Dispose(){Disposed=true;}
    }
    public sealed class ControlledStartupSettings : IStartupSettingsLauncher
    {
        public int Calls;public bool Fail;
        public void Open(){Calls++;if(Fail)throw new InvalidOperationException("SIMULATED startup settings failure");}
    }
    public sealed class StartupLaunchCapture
    {
        public string Uri;public void Start(string uri){Uri=uri;}
        public WindowsStartupSettingsLauncher Launcher(){return new WindowsStartupSettingsLauncher(Start);}
    }
    public static class StartupWindowEvents
    {
        public static bool RequestClose(ShellForm form)
        {
            var args=new System.Windows.Forms.FormClosingEventArgs(System.Windows.Forms.CloseReason.UserClosing,false);
            typeof(ShellForm).GetMethod("OnFormClosing",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic).Invoke(form,new object[]{args});
            return args.Cancel;
        }
    }
    public sealed class ReentrantStartupConfirmation : ITransparencyConfirmation
    {
        public ShellForm Form;public int Calls;public bool Nested;
        public bool Confirm(string title,string message){Calls++;Nested=Form.RequestStartup(StartupAction.Read,null)||Form.RequestPower(PowerAction.Read)||Form.RequestVisual(VisualAction.Read)||Form.RequestTransparency(TransparencyAction.Read);return true;}
    }
}
