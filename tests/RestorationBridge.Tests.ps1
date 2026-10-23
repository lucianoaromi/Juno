#requires -Version 5.1
# Real C# runspace/service + facade. All Windows and backup frontiers use a private JSON fixture.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$restBridgeRoot=Split-Path $PSScriptRoot -Parent
if(-not ('Juno.Preview.Testing.ControlledRecovery' -as [type])){
    $files=@(Get-ChildItem (Join-Path $restBridgeRoot 'ui') -Filter *.cs|ForEach-Object FullName)+@(Get-ChildItem $PSScriptRoot -Filter *.TestSupport.cs|ForEach-Object FullName)
    Add-Type -Path $files -ReferencedAssemblies @('System.Windows.Forms','System.Drawing','System.Management','System.Web.Extensions',[Management.Automation.PSObject].Assembly.Location)
}
. (Join-Path $restBridgeRoot 'BackupStore.ps1')
. (Join-Path $PSScriptRoot 'Restoration.Fake.ps1')
function New-RestBridgeFixture([string]$kind) {
    $folder=Join-Path $TestDrive ('Restauración aislada '+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder)
    foreach($name in @('BackupStore','RecoveryOperations','UiSupport','PowerOperations','TransparencyOperations','VisualInterop','StartupOperations','BackgroundInventory','PermisosUsuario','PermisosSegundoPlano','PowerAdapter','TransparencyAdapter','StartupAdapter','RecoveryAdapter')){
        $source=[IO.File]::ReadAllText((Join-Path $restBridgeRoot ($name+'.ps1')))
        if($name -eq 'BackupStore'){$source=$source.Replace('Global\JUNO.0.8.State',('Local\Juno.Tests.RestBridge.'+[Guid]::NewGuid().ToString('N')))}
        [IO.File]::WriteAllText((Join-Path $folder ($name+'.ps1')),$source,[Text.UTF8Encoding]::new($true))
    }
    Reset-RestorationFake;if($kind){Add-RestorationBackup $kind}
    $state=Join-Path $folder 'state.json';[IO.File]::WriteAllText($state,($global:JunoRestFake|ConvertTo-Json -Depth 24),[Text.UTF8Encoding]::new($true))
    $fake=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Restoration.Fake.ps1'))
    $fake+="`r`n`$script:RestorationFakeState='"+$state.Replace("'","''")+"'`r`n`$global:JunoRestFake=Get-Content -LiteralPath `$script:RestorationFakeState -Raw|ConvertFrom-Json`r`n"
    [IO.File]::AppendAllText((Join-Path $folder 'RecoveryAdapter.ps1'),("`r`n"+$fake),[Text.UTF8Encoding]::new($true))
    [pscustomobject]@{Root=$folder;State=$state;Service=(New-Object Juno.Preview.PowerShellRecoveryService($folder))}
}
function Wait-RestBridge($task){if(-not $task.Wait(15000)){throw 'TEST: service timeout'};return $task.GetAwaiter().GetResult()}
Describe 'Puente de Restauración: runspace real aislado x86/x64' {
    AfterEach {if(Get-Variable fixture -Scope Script -ErrorAction SilentlyContinue){$fixture.Service.Dispose()}}
    It 'lee y recupera <Kind> a través del contrato JSON sin otras escrituras' -TestCases @(@{Kind='Power'},@{Kind='Transparency'},@{Kind='Startup'},@{Kind='BackgroundUser'},@{Kind='BackgroundPolicy'},@{Kind='Trim'}) {
        param($Kind)$script:fixture=New-RestBridgeFixture $Kind;$hash=(Get-FileHash -LiteralPath $fixture.State).Hash
        $r=Wait-RestBridge ($fixture.Service.ExecuteAsync('','',$false));$r.Outcome|Should Be Read;$r.Items.Count|Should Be 6
        (Get-FileHash -LiteralPath $fixture.State).Hash|Should Be $hash
        $item=@($r.Items|Where-Object Id -eq $Kind)[0];$item.CanRestore|Should Be $true
        $after=Wait-RestBridge ($fixture.Service.ExecuteAsync($Kind,$item.Token,$true));$after.Outcome|Should Be Restored
        $state=Get-Content -LiteralPath $fixture.State -Raw|ConvertFrom-Json;$state.Writes|Should Be 1;($state.Calls -join ',')|Should Be $Kind;$state.History.Count|Should Be 1
    }
    It 'rechaza solicitudes no confirmadas e identificadores ajenos antes de importar' {
        $s=New-Object Juno.Preview.PowerShellRecoveryService((Join-Path $TestDrive 'missing'))
        try{(Wait-RestBridge ($s.ExecuteAsync('Power','TOKEN',$false))).Outcome|Should Be Cancelled;(Wait-RestBridge ($s.ExecuteAsync('Visual','TOKEN',$true))).Outcome|Should Be Cancelled}finally{$s.Dispose()}
    }
    It 'rechaza un token anterior sin tocar datos' {
        $script:fixture=New-RestBridgeFixture Transparency;$hash=(Get-FileHash -LiteralPath $fixture.State).Hash
        (Wait-RestBridge ($fixture.Service.ExecuteAsync('Transparency','OLD',$true))).Outcome|Should Be Conflict
        (Get-FileHash -LiteralPath $fixture.State).Hash|Should Be $hash
    }
    It 'un no-op del motor no se traduce en éxito del servicio' {
        $script:fixture=New-RestBridgeFixture Power;$state=Get-Content -LiteralPath $fixture.State -Raw|ConvertFrom-Json;$state.Mode='NoOp'
        [IO.File]::WriteAllText($fixture.State,($state|ConvertTo-Json -Depth 24),[Text.UTF8Encoding]::new($true))
        $r=Wait-RestBridge ($fixture.Service.ExecuteAsync('','',$false));$token=@($r.Items|Where-Object Id -eq Power)[0].Token
        (Wait-RestBridge ($fixture.Service.ExecuteAsync('Power',$token,$true))).Outcome|Should Be Partial
    }
    It 'se serializan las solicitudes y el servicio sigue disponible tras una lectura' {
        $script:fixture=New-RestBridgeFixture ''
        [IO.File]::AppendAllText((Join-Path $fixture.Root 'RecoveryAdapter.ps1'),"`r`nStart-Sleep -Milliseconds 200`r`n",[Text.UTF8Encoding]::new($true))
        $first=$fixture.Service.ExecuteAsync('','',$false);(Wait-RestBridge ($fixture.Service.ExecuteAsync('','',$false))).Outcome|Should Be Busy
        (Wait-RestBridge $first).Outcome|Should Be Read;(Wait-RestBridge ($fixture.Service.ExecuteAsync('','',$false))).Outcome|Should Be Read
    }
    It 'rechaza categorías duplicadas o contratos incompatibles sin exponer detalles técnicos' {
        $script:fixture=New-RestBridgeFixture ''
        $bad="`r`nfunction Invoke-JunoRecoveryRequest { [pscustomobject]@{Items=@((New-JunoRecoveryItem Power),(New-JunoRecoveryItem Power));Outcome='Read';Message='PRIVATE'} }`r`n"
        [IO.File]::AppendAllText((Join-Path $fixture.Root 'RecoveryAdapter.ps1'),$bad,[Text.UTF8Encoding]::new($true))
        $r=Wait-RestBridge ($fixture.Service.ExecuteAsync('','',$false));$r.Outcome|Should Be Failed;$r.Message|Should Not Match PRIVATE;$r.Details|Should Not BeNullOrEmpty
    }
    It 'dispose impide nuevos trabajos sin detener procesos' {
        $script:fixture=New-RestBridgeFixture '';$fixture.Service.Dispose()
        (Wait-RestBridge ($fixture.Service.ExecuteAsync('','',$false))).Outcome|Should Be Busy
    }
}
