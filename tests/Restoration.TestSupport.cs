using System;
using System.Threading.Tasks;
namespace Juno.Preview.Testing
{
    public sealed class ControlledRecovery : IRecoveryService
    {
        public int Calls,Writes;public string Id,Token;public bool Confirmed,Disposed;
        public TaskCompletionSource<RecoveryResult> Completion=new TaskCompletionSource<RecoveryResult>();
        public Task<RecoveryResult> ExecuteAsync(string id,string token,bool confirmed){Calls++;if(id!="")Writes++;Id=id;Token=token;Confirmed=confirmed;return Completion.Task;}
        public void Complete(RecoveryResult result){Completion.TrySetResult(result);}
        public void Next(){Completion=new TaskCompletionSource<RecoveryResult>();}
        public void Dispose(){Disposed=true;}
    }
    public sealed class ReentrantRecoveryConfirmation : ITransparencyConfirmation
    {
        public ShellForm Form;public bool Nested;
        public bool Confirm(string title,string message){Nested=Form.RequestRecovery(null)||Form.RequestPower(PowerAction.Read)||Form.RequestTransparency(TransparencyAction.Read)||Form.RequestVisual(VisualAction.Read)||Form.RequestStartup(StartupAction.Read,null);return true;}
    }
}
