using System.Threading.Tasks;
namespace Juno.Preview.Testing
{
    public sealed class ControlledVisualSettings : IVisualSettingsLauncher
    {
        public int Calls;
        public bool Fail;
        public void Open(){Calls++;if(Fail)throw new System.InvalidOperationException("SIMULATED Windows settings launch failure");}
    }
    public sealed class ControlledVisual : IVisualService
    {
        public int Calls,WriteCalls;
        public bool Disposed;
        public VisualAction LastAction;
        public TaskCompletionSource<VisualResult> Completion=new TaskCompletionSource<VisualResult>();
        public TransparencyReview PendingReview {get;set;}
        public Task<VisualResult> ExecuteAsync(VisualAction action,bool confirmed){Calls++;if(action!=VisualAction.Read)WriteCalls++;LastAction=action;return Completion.Task;}
        public void Complete(VisualResult value){Completion.TrySetResult(value);}
        public void Next(){Completion=new TaskCompletionSource<VisualResult>();}
        public void Dispose(){Disposed=true;}
    }
}
