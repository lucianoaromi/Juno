using System;
using System.Threading.Tasks;
namespace Juno.Preview.Testing
{
    public sealed class ControlledPower : IPowerService
    {
        public int Calls,WriteCalls;
        public bool Disposed;
        public PowerAction LastAction;
        public TaskCompletionSource<PowerResult> Completion=new TaskCompletionSource<PowerResult>();
        public TransparencyReview PendingReview {get;set;}
        public Task<PowerResult> ExecuteAsync(PowerAction action,bool confirmed){Calls++;if(action!=PowerAction.Read)WriteCalls++;LastAction=action;return Completion.Task;}
        public string LastTarget;
        public bool LastCreate;
        public Task<PowerResult> ExecuteAsync(PowerAction action,bool confirmed,string targetGuid,bool allowCreate){LastTarget=targetGuid;LastCreate=allowCreate;return ExecuteAsync(action,confirmed);}
        public void Complete(PowerResult value){Completion.TrySetResult(value);}
        public void Next(){Completion=new TaskCompletionSource<PowerResult>();}
        public void Dispose(){Disposed=true;}
    }
    public sealed class ControlledPowerPlans : IPowerPlansLauncher
    {
        public int Calls;
        public void Open(){Calls++;}
    }
    public sealed class ControlledPowerSelection : IPowerPlanSelection
    {
        public string Selected;
        public int Calls;
        public string Choose(PowerPlanChoice[] choices){Calls++;return Selected;}
    }
}
