using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Juno.Preview.Testing
{
    // Se compila solamente en las pruebas; nunca se distribuye al trabajador.
    public sealed class ControlledQuery : IDashboardQuery
    {
        public int Calls;
        public CancellationToken LastToken;
        public TaskCompletionSource<DashboardSnapshot> Completion=new TaskCompletionSource<DashboardSnapshot>();
        public Task<DashboardSnapshot> FetchAsync(CancellationToken token){Calls++;LastToken=token;return Completion.Task;}
        public void Complete(DashboardSnapshot snapshot){Completion.TrySetResult(snapshot);}
        public void Fail(){Completion.TrySetException(new InvalidOperationException("Fixture"));}
        public void CompleteInBackground(DashboardSnapshot snapshot)
        {Task.Run(()=>{Thread.Sleep(50);Complete(snapshot);});}
        public void Next(){Completion=new TaskCompletionSource<DashboardSnapshot>();}
    }
    public sealed class FixtureReadApi : IWindowsReadApi
    {
        public bool Fail;
        public int Calls;
        public Dictionary<string,string> Fields=new Dictionary<string,string>();
        public Dictionary<string,string> Read(string key){Calls++;if(Fail)throw new UnauthorizedAccessException("Fixture");return Fields;}
    }
}
