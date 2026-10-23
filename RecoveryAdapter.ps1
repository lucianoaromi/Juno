#requires -Version 5.1
# Recovery-only facade. Importing defines functions; existing engines retain all writes and storage protections.
function New-JunoRecoveryItem([string]$kind) {
    [pscustomobject]@{Id=$kind;State='Empty';CanRestore=$false;Token='';Count=0;Message='';Details=''}
}
function Get-JunoRecoveryToken($data) {
    Get-JunoHash ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $data -Depth 24 -Compress)))
}
function Test-JunoRecoveryUserProvenance([ValidateSet('Startup','BPU')][string]$kind) {
    Assert-JunoLease
    $path=Get-JunoStorePath $kind User
    if(-not(Test-Path -LiteralPath $path)){return $false}
    $document=ConvertFrom-JunoBytes (Read-JunoBytes $path)
    if($null -eq $document -or $document.PSObject.Properties.Name -notcontains 'Format'){return $false}
    # Old raw user files can be accepted by the historical engines without a machine identity.
    # The central view requires a fully attributable envelope; do not change/migrate that evidence.
    $null=Read-JunoDocument $path $kind User
    return $true
}
function Get-DiskTrimState {
    # Same read boundary as the classic engine, without loading its window or maintenance actions.
    $output=(& (Get-JunoSystemTool 'fsutil.exe') behavior query DisableDeleteNotify 2>&1|Out-String)
    if($LASTEXITCODE -ne 0){throw 'No se pudo consultar TRIM.'}
    $match=[regex]::Match($output,'(?im)^\s*NTFS\s+DisableDeleteNotify\s*=\s*([01])\b')
    if(-not $match.Success){throw 'Windows devolvió un estado de TRIM no reconocido.'}
    [pscustomobject]@{State=[int]$match.Groups[1].Value}
}
function Read-JunoRecoveryItem([string]$kind,[bool]$admin) {
    Assert-JunoLease
    $item=New-JunoRecoveryItem $kind
    try {
        if($kind -in @('Power','BackgroundPolicy','Trim') -and -not $admin){return $item}
        switch -CaseSensitive ($kind) {
            'Power' {
                $backup=Get-JunoPowerBackup
                if($null -eq $backup.PowerScheme){
                    $legacy=Get-JunoMachineLegacy Power
                    if($null -eq $legacy){return $item}
                    $item.State='Blocked';$item.Message='Este respaldo antiguo necesita una recuperación supervisada.';return $item
                }
                $view=Get-JunoPowerView
                $item.Count=1;$item.Token=Get-JunoRecoveryToken $backup
                $item.CanRestore=$view.CanRestore -and -not $view.Historical -and -not $view.BackupIssue -and $view.Outcome -notin @('Failed','Conflict')
                $item.State=if($item.CanRestore){'Ready'}elseif($view.Outcome -eq 'Conflict'){'Conflict'}else{'Blocked'}
            }
            'Transparency' {
                $backup=Get-Backup
                if($null -eq $backup.TransparencyBackup){return $item}
                $view=Get-JunoTransparencyView
                $item.Count=1;$item.Token=Get-JunoRecoveryToken $backup
                $item.CanRestore=$view.CanRestore -and -not $view.Historical -and -not $view.BackupIssue -and $view.Outcome -notin @('Failed','Conflict')
                $item.State=if($item.CanRestore){'Ready'}elseif($view.Outcome -eq 'Conflict'){'Conflict'}else{'Blocked'}
            }
            'Startup' {
                $backup=Get-StartupBackup;Assert-JunoStartupData $backup
                if($backup.Entries.Count -eq 0){return $item}
                $item.Count=$backup.Entries.Count;$item.Token=Get-JunoRecoveryToken $backup
                if(@($backup.Entries|Where-Object{$_.ApprovalHive -ceq 'CurrentUser'}).Count -gt 0 -and -not(Test-JunoRecoveryUserProvenance Startup)){
                    $item.State='Blocked';$item.Message='Este respaldo antiguo necesita una recuperación supervisada.';return $item
                }
                $legacy=if($admin -and -not(Test-Path -LiteralPath (Get-JunoStorePath Startup Machine))){Get-JunoMachineLegacy Startup}else{$null}
                if($null -ne $legacy){$item.State='Blocked';$item.Message='Este respaldo antiguo necesita una recuperación supervisada.';return $item}
                $available=0;$conflicts=0;$unavailable=0
                foreach($record in $backup.Entries){
                    try{
                        $copy=Copy-JunoObject $record
                        if((Get-StartupSourceFingerprint $copy) -cne $copy.Fingerprint){$conflicts++;continue}
                        $actual=Get-StartupApprovalSnapshot (Read-StartupRegValue $copy.ApprovalHive $copy.ApprovalView $copy.ApprovalKey $copy.ApprovalValue)
                        Initialize-StartupTransaction $copy;Sync-StartupTransaction $copy $actual
                        if($copy.ApprovalHive -ne 'LocalMachine' -or $admin){$available++}else{$unavailable++}
                    }catch{if($_.Exception.Message -match 'Conflicto|cambio fuera|cambió fuera'){$conflicts++}else{$unavailable++}}
                }
                $item.CanRestore=$available -gt 0;$item.State=if($item.CanRestore){'Ready'}elseif($unavailable -eq 0 -and $conflicts -gt 0){'Conflict'}else{'Blocked'}
                if($available -gt 0 -and $available -lt $item.Count){$item.Message='Podés recuperar parte de los cambios. Los demás conservarán su respaldo.'}
            }
            'BackgroundUser' {
                $backup=Get-BPUBackup
                if($backup.Items.Count -eq 0){return $item}
                $item.Count=$backup.Items.Count;$item.Token=Get-JunoRecoveryToken $backup
                if(-not(Test-JunoRecoveryUserProvenance BPU)){$item.State='Blocked';$item.Message='Este respaldo antiguo necesita una recuperación supervisada.';return $item}
                $view=Get-BPPPermissionView
                $rows=@($view.Rows|Where-Object{$_.Scope -ceq 'User'})
                $item.CanRestore=$view.BackupsValid -and $rows.Count -eq $item.Count -and @($rows|Where-Object{-not $_.CanRestore}).Count -eq 0
                $item.State=if($item.CanRestore){'Ready'}else{'Blocked'}
            }
            'BackgroundPolicy' {
                $backup=Read-BPPBackup
                if($backup.Owned.Count -eq 0){return $item}
                $item.Count=$backup.Owned.Count;$item.Token=Get-JunoRecoveryToken $backup
                if($backup.PSObject.Properties.Name -notcontains 'Transaction' -or $backup.Transaction.Phase -eq 'Restored'){
                    $item.State='Blocked';$item.Message='Este respaldo antiguo necesita una recuperación supervisada.';return $item
                }
                # A sidecar awaiting machine import must never be promoted during a query or recovery here.
                if(-not(Test-Path -LiteralPath (Get-JunoStorePath Policy Machine))){$item.State='Blocked';return $item}
                $view=Get-BPPPermissionView
                $rows=@($view.Rows|Where-Object{$_.Scope -ceq 'Policy' -and $backup.Owned -contains $_.Family})
                $item.CanRestore=$view.BackupsValid -and $rows.Count -eq $item.Count -and @($rows|Where-Object{-not $_.CanRestore}).Count -eq 0
                $item.State=if($item.CanRestore){'Ready'}else{'Blocked'}
            }
            'Trim' {
                $backup=Read-JunoStore Trim Machine $null
                if($null -eq $backup){
                    if($null -ne (Get-JunoMachineLegacy Trim)){$item.State='Blocked';$item.Message='Este respaldo antiguo necesita una recuperación supervisada.'}
                    return $item
                }
                if($backup.PSObject.Properties.Name -notcontains 'Transaction'){$item.State='Blocked';return $item}
                if($backup.Transaction.Phase -eq 'Restored'){return $item}
                $state=(Get-DiskTrimState).State;Assert-JunoInt $state 0 1
                $copy=Copy-JunoObject $backup.Transaction;Sync-JunoScalar $copy $state
                $item.Count=1;$item.Token=Get-JunoRecoveryToken $backup;$item.CanRestore=$true;$item.State='Ready'
            }
            default {throw 'Recuperación no permitida.'}
        }
        if(-not $item.Message){
            $item.Message=switch($item.State){'Ready'{'Hay cambios anteriores guardados por JUNO.'}'Conflict'{'La configuración cambió fuera de JUNO. El respaldo se conserva.'}default{'No se puede recuperar automáticamente. Comprobá permisos y compatibilidad.'}}
        }
    }catch{
        $item.State=if($_.Exception.Message -match 'Conflicto|cambio fuera|cambió fuera'){'Conflict'}else{'Error'}
        $item.CanRestore=$false;$item.Details=$_.Exception.ToString()
        $item.Message=if($item.State -eq 'Conflict'){'La configuración cambió fuera de JUNO. El respaldo se conserva.'}else{'No se pudo validar esta recuperación. El respaldo se conserva.'}
    }
    return $item
}
function Get-JunoRecoveryView {
    Assert-JunoLease
    $admin=Test-JunoAdmin
    $items=@(foreach($kind in @('Power','Transparency','Startup','BackgroundUser','BackgroundPolicy','Trim')){Read-JunoRecoveryItem $kind $admin})
    $errors=@($items|Where-Object{$_.State -eq 'Error'})
    [pscustomobject]@{Items=$items;Outcome=$(if($errors.Count){'Partial'}else{'Read'});Message='';Details=(@($errors|ForEach-Object{$_.Details}) -join "`r`n");MachineChecked=$admin;Attempted=''}
}
function Get-JunoRecoveryProof([string]$kind) {
    switch($kind){
        Power{(Get-JunoPowerBackup).PowerScheme}
        Transparency{(Get-Backup).TransparencyBackup}
        Startup{(Get-StartupBackup).Entries}
        BackgroundUser{(Get-BPUBackup).Items}
        BackgroundPolicy{Read-BPPBackup}
        Trim{(Read-JunoStore Trim Machine $null).Original}
    }
}
function Test-JunoRecoveryProof([string]$kind,$proof) {
    switch($kind){
        Power{return (Get-ActivePlan).Guid -ieq $proof}
        Transparency{return (Test-JunoEqual (Get-TransparencySnapshot) $proof)}
        Startup{
            foreach($record in @($proof)){
                if((Get-StartupSourceFingerprint $record) -cne $record.Fingerprint){return $false}
                $actual=Get-StartupApprovalSnapshot (Read-StartupRegValue $record.ApprovalHive $record.ApprovalView $record.ApprovalKey $record.ApprovalValue)
                if(-not(Test-StartupApprovalSnapshot $actual ([pscustomobject]@{Exists=[bool]$record.OriginalExists;Data=$record.OriginalData}))){return $false}
            };return $true
        }
        BackgroundUser{
            foreach($record in @($proof)){
                $actual=Get-BPUState $record.Family
                if(-not $actual.Available){return $false}
                foreach($field in @('Disabled','DisabledByUser')){if(-not(Test-BPUValueSnapshot $actual.$field $record.$field)){return $false}}
            };return $true
        }
        BackgroundPolicy{
            $actual=Get-JunoPolicyState
            foreach($field in @('Deny','Global')){if(-not(Test-JunoEqual $actual.$field $proof.Transaction.Original.$field)){return $false}}
            foreach($field in @('Allow','UserControl')){if(-not(Test-JunoEqual $actual.$field $proof.Transaction.Guard.$field)){return $false}}
            return $true
        }
        Trim{return ((Get-DiskTrimState).State -eq $proof -and (Read-JunoStore Trim Machine $null).Transaction.Phase -eq 'Restored')}
    }
    return $false
}
function Invoke-JunoRecoveryRequest {
    param([ValidateSet('Read','Restore')][string]$Action,[ValidateSet('','Power','Transparency','Startup','BackgroundUser','BackgroundPolicy','Trim')][string]$Id='',[string]$Token='',[switch]$Confirmed)
    $result=[pscustomobject]@{Items=@();Outcome='Failed';Message='No se pudo comprobar la recuperación. Conservá los respaldos.';Details='';MachineChecked=$false;Attempted=''}
    if($Action -eq 'Restore' -and (-not $Confirmed -or -not $Id)){$result.Outcome='Cancelled';$result.Message='Restauración cancelada.';return $result}
    $owned=$false;$attempted=''
    try{
        Enter-JunoLease;$owned=$true
        $result=Get-JunoRecoveryView
        if($Action -eq 'Read'){return $result}
        $item=@($result.Items|Where-Object{$_.Id -ceq $Id})
        if($item.Count -ne 1 -or -not $item[0].CanRestore){$result.Outcome='Blocked';$result.Message='La recuperación no está disponible. Actualizá los respaldos.';return $result}
        if(-not $Token -or $item[0].Token -cne $Token){$result.Outcome='Conflict';$result.Message='El respaldo cambió desde la consulta. Actualizá antes de restaurar.';return $result}
        $proof=Copy-JunoObject (Get-JunoRecoveryProof $Id)
        $attempted=$Id
        switch($Id){
            Power{$null=Restore-PowerPlan}
            Transparency{$null=Restore-Transparency}
            Startup{$null=Restore-StartupState}
            BackgroundUser{$rows=@((Get-BPPPermissionView).Rows|Where-Object{$_.Scope -ceq 'User'});$null=Invoke-BPPSelection Restore $rows $true}
            BackgroundPolicy{$ownedFamilies=(Read-BPPBackup).Owned;$rows=@((Get-BPPPermissionView).Rows|Where-Object{$_.Scope -ceq 'Policy' -and $ownedFamilies -contains $_.Family});$null=Invoke-BPPSelection Restore $rows $true}
            Trim{$null=Invoke-JunoTrim $true}
        }
        $verified=Test-JunoRecoveryProof $Id $proof
        $result=Get-JunoRecoveryView;$result.Attempted=$attempted
        $remaining=@($result.Items|Where-Object{$_.Id -ceq $Id})
        if(-not $verified -or $remaining.Count -ne 1 -or $remaining[0].State -ne 'Empty'){
            $result.Outcome='Partial';$result.Message='No se pudo recuperar todo. Comprobá el estado; los cambios pendientes conservan su respaldo.';return $result
        }
        $result.Outcome='Restored';$result.Message='Se recuperó y comprobó la configuración anterior.'
        if($Id -like 'Background*'){$result.Message='Se recuperaron y comprobaron los valores anteriores. La actividad de las apps depende de Windows.'}
        return $result
    }catch{
        $failure=$_.Exception
        if($owned){try{$result=Get-JunoRecoveryView}catch{}}
        $result.Attempted=$attempted;$result.Outcome='Failed';$result.Message='No se pudo completar la recuperación. Comprobá el estado y conservá los respaldos.';$result.Details+="`r`n"+$failure.ToString()
        return $result
    }finally{if($owned){Exit-JunoLease}}
}
