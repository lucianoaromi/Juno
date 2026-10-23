# Test boundaries only. Never import this file in the application.
function Reset-RestorationFake {
    $global:JunoRestFake=[pscustomobject]@{Admin=$true;Mode='Normal';Writes=0;Calls=@();History=@();Invalid='';Legacy='';ViewFailure='';Allowed=$true;Power=[pscustomobject]@{PowerScheme=$null};General=[pscustomobject]@{TransparencyBackup=$null};Startup=[pscustomobject]@{Entries=@()};User=[pscustomobject]@{Items=@()};Policy=[pscustomobject]@{Owned=@()};Trim=$null;CurrentPower='bbbbbbbb-2222-3333-4444-555555555555';CurrentTransparency=[pscustomobject]@{Exists=$true;Kind='DWord';Value='0'};CurrentTrim=0}
}
function Add-RestorationBackup([string]$kind) {
    switch($kind){
        Power{$global:JunoRestFake.Power=[pscustomobject]@{PowerScheme='aaaaaaaa-2222-3333-4444-555555555555'}}
        Transparency{$global:JunoRestFake.General.TransparencyBackup=[pscustomobject]@{Exists=$true;Kind='DWord';Value='1'}}
        Startup{$global:JunoRestFake.Startup.Entries=@([pscustomobject]@{Id='CurrentUser|Default|Software\Microsoft\Windows\CurrentVersion\Run|Example';Name='Example';ApprovalHive='CurrentUser';ApprovalView='Default';ApprovalKey='Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';ApprovalValue='Example';SourceType='Registro';SourceHive='CurrentUser';SourceView='Default';SourceKey='Software\Microsoft\Windows\CurrentVersion\Run';SourceValue='Example';Fingerprint=('A'*43+'=');OriginalExists=$false;OriginalData=$null;LastWrittenData='AgAAAAAAAAAAAAAA';Transaction=[pscustomobject]@{Version=1;Confirmed=[pscustomobject]@{Exists=$true;Data='AgAAAAAAAAAAAAAA'};Pending=$null}})}
        BackgroundUser{$global:JunoRestFake.User.Items=@([pscustomobject]@{Family='Example_pkg';Disabled=[pscustomobject]@{Exists=$true;Value=0};DisabledByUser=[pscustomobject]@{Exists=$false;Value=$null}})}
        BackgroundPolicy{$none=[pscustomobject]@{Exists=$false;Value=$null};$global:JunoRestFake.Policy=[pscustomobject]@{Owned=@('Example_pkg');Transaction=[pscustomobject]@{Phase='Applied';Original=[pscustomobject]@{Deny=$none;Global=$none};Guard=[pscustomobject]@{Allow=$none;UserControl=$none}}}}
        Trim{$global:JunoRestFake.Trim=[pscustomobject]@{Original=1;Transaction=[pscustomobject]@{Confirmed=0;Pending=$null;Phase='Applied'}}}
    }
    $global:JunoRestFake.History+=@(ConvertTo-Json -InputObject $global:JunoRestFake -Depth 24 -Compress)
}
function Assert-RestorationReadable([string]$kind){Assert-JunoLease;if($global:JunoRestFake.Invalid -ceq $kind){throw 'SIMULATED: respaldo inválido, identidad o ámbito incompatible'}}
function Test-JunoRecoveryUserProvenance($kind){return $global:JunoRestFake.Legacy -notin @('UnverifiableUser')}
function Test-JunoAdmin {$global:JunoRestFake.Admin}
function Get-JunoPowerBackup {Assert-RestorationReadable Power;Copy-JunoObject $global:JunoRestFake.Power}
function Get-Backup {Assert-RestorationReadable Transparency;Copy-JunoObject $global:JunoRestFake.General}
function Get-StartupBackup {Assert-RestorationReadable Startup;Copy-JunoObject $global:JunoRestFake.Startup}
function Get-BPUBackup {Assert-RestorationReadable BackgroundUser;Copy-JunoObject $global:JunoRestFake.User}
function Read-BPPBackup {Assert-RestorationReadable BackgroundPolicy;Copy-JunoObject $global:JunoRestFake.Policy}
function Read-JunoStore($kind,$scope,$default){if($kind -cne 'Trim' -or $scope -cne 'Machine'){throw 'TEST: unexpected store'};Assert-RestorationReadable Trim;Copy-JunoObject $global:JunoRestFake.Trim}
function Get-JunoMachineLegacy($kind){if($global:JunoRestFake.Legacy -ceq $kind){return [pscustomobject]@{Data='historic'}};return $null}
function Get-JunoStorePath($kind,$scope){return $PSCommandPath} # fixture itself exists, never a production backup
function Get-RestorationFakeView([string]$kind){if($global:JunoRestFake.ViewFailure -eq $kind){throw 'SIMULATED query error'};[pscustomobject]@{CanRestore=$global:JunoRestFake.Allowed;Historical=($global:JunoRestFake.Legacy -eq $kind);BackupIssue='';Outcome=$(if($global:JunoRestFake.Allowed){'Read'}else{'Conflict'})}}
function Get-JunoPowerView {Get-RestorationFakeView Power}
function Get-JunoTransparencyView {Get-RestorationFakeView Transparency}
function Get-StartupSourceFingerprint($record){if(-not $global:JunoRestFake.Allowed){return 'CHANGED'};return ('A'*43+'=')}
function Read-StartupRegValue($hive,$view,$key,$name){if($global:JunoRestFake.Startup.Entries.Count -eq 0){[pscustomobject]@{Exists=$false;Data=$null;Kind=$null}}else{[pscustomobject]@{Exists=$true;Data=[Convert]::FromBase64String('AgAAAAAAAAAAAAAA');Kind='Binary'}}}
function Get-BPPPermissionView {
    $rows=@();foreach($item in $global:JunoRestFake.User.Items){$rows+=@([pscustomobject]@{Scope='User';Family=$item.Family;CanRestore=$global:JunoRestFake.Allowed})}
    foreach($family in $global:JunoRestFake.Policy.Owned){$rows+=@([pscustomobject]@{Scope='Policy';Family=$family;CanRestore=$global:JunoRestFake.Allowed})}
    [pscustomobject]@{Rows=$rows;BackupsValid=$true}
}
function Get-DiskTrimState {[pscustomobject]@{State=$global:JunoRestFake.CurrentTrim}}
function Get-ActivePlan {[pscustomobject]@{Guid=$global:JunoRestFake.CurrentPower}}
function Get-TransparencySnapshot {$global:JunoRestFake.CurrentTransparency}
function Get-BPUState($family){[pscustomobject]@{Available=$true;Disabled=[pscustomobject]@{Exists=$true;Value=0};DisabledByUser=[pscustomobject]@{Exists=$false;Value=$null}}}
function Get-JunoPolicyState {$none=[pscustomobject]@{Exists=$false;Value=$null};[pscustomobject]@{Deny=$none;Global=$none;Allow=$none;UserControl=$none}}
function Invoke-RestorationFakeWrite([string]$kind){
    Assert-JunoLease;$global:JunoRestFake.Writes++;$global:JunoRestFake.Calls+=@($kind)
    if($global:JunoRestFake.Mode -eq 'Fail'){throw 'SIMULATED write failure'}
    if($global:JunoRestFake.Mode -in @('NoOp','Partial')){return}
    if($global:JunoRestFake.Mode -ne 'ClearOnly'){
        switch($kind){Power{$global:JunoRestFake.CurrentPower=$global:JunoRestFake.Power.PowerScheme}Transparency{$global:JunoRestFake.CurrentTransparency=Copy-JunoObject $global:JunoRestFake.General.TransparencyBackup}Trim{$global:JunoRestFake.CurrentTrim=$global:JunoRestFake.Trim.Original}}
    }
    switch($kind){Power{$global:JunoRestFake.Power.PowerScheme=$null}Transparency{$global:JunoRestFake.General.TransparencyBackup=$null}Startup{$global:JunoRestFake.Startup.Entries=@()}BackgroundUser{$global:JunoRestFake.User.Items=@()}BackgroundPolicy{$global:JunoRestFake.Policy.Owned=@()}Trim{$global:JunoRestFake.Trim.Transaction.Phase='Restored'}}
    if(Get-Variable -Name RestorationFakeState -Scope Script -ErrorAction SilentlyContinue){[IO.File]::WriteAllText($script:RestorationFakeState,($global:JunoRestFake|ConvertTo-Json -Depth 24),[Text.UTF8Encoding]::new($true))}
}
function Restore-PowerPlan {Invoke-RestorationFakeWrite Power}
function Restore-Transparency {Invoke-RestorationFakeWrite Transparency}
function Restore-StartupState {Invoke-RestorationFakeWrite Startup}
function Invoke-BPPSelection($action,$rows,$confirmed){if($action -cne 'Restore' -or -not $confirmed){throw 'TEST: unsafe background request'};$scopes=@($rows.Scope|Select-Object -Unique);if($scopes.Count -ne 1){throw 'TEST: mixed scope'};Invoke-RestorationFakeWrite $(if($scopes[0] -ceq 'User'){'BackgroundUser'}else{'BackgroundPolicy'})}
function Invoke-JunoTrim([bool]$restore){if(-not $restore){throw 'TEST: new optimization forbidden'};Invoke-RestorationFakeWrite Trim}
function Import-JunoMachineLegacy {throw 'TEST: import forbidden'}
function Write-JunoStore {throw 'TEST: unexpected production write'}
function Get-JunoIdentity {throw 'TEST: real identity forbidden'}
function Get-JunoMachineFolder {throw 'TEST: real folder forbidden'}
function Set-JunoEffects {throw 'TEST: visual effects forbidden'}
function Start-Process {throw 'TEST: real process forbidden'}
Reset-RestorationFake
