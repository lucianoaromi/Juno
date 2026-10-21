using System;
using System.Threading.Tasks;

namespace Juno.Preview.Testing
{
    public sealed class ControlledTransparency : ITransparencyService
    {
        public int Calls,WriteCalls;
        public bool Disposed;
        public TransparencyAction LastAction;
        public TaskCompletionSource<TransparencyResult> Completion=new TaskCompletionSource<TransparencyResult>();
        public TransparencyReview PendingReview {get;set;}
        public Task<TransparencyResult> ExecuteAsync(TransparencyAction action,bool confirmed){Calls++;if(action!=TransparencyAction.Read)WriteCalls++;LastAction=action;return Completion.Task;}
        public void Complete(TransparencyResult value){Completion.TrySetResult(value);}
        public void Next(){Completion=new TaskCompletionSource<TransparencyResult>();}
        public void Dispose(){Disposed=true;}
    }
    public sealed class ControlledConfirmation : ITransparencyConfirmation
    {
        public bool Accept;
        public int Calls;
        public string LastTitle,LastMessage;
        public bool Confirm(string title,string message){Calls++;LastTitle=title;LastMessage=message;return Accept;}
    }
    public sealed class PumpingConfirmation : ITransparencyConfirmation
    {
        public int Calls;
        public bool Confirm(string title,string message){
            Calls++;if(Calls>1)return false;
            var clock=System.Diagnostics.Stopwatch.StartNew();
            while(clock.ElapsedMilliseconds<350){System.Windows.Forms.Application.DoEvents();System.Threading.Thread.Sleep(5);}
            return true;
        }
    }
}
