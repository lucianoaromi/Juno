#requires -Version 5.1
# Adaptación: solo definiciones al importar. El motor estable conserva todas las escrituras.
function Get-JunoPowerCapabilities { return [Juno.Preview.PowerPlatform]::ModernStandby() }
function New-JunoPowerView {
    return [pscustomobject]@{ActiveGuid=$null;ActiveName='Estado aún no consultado';HighAvailable=$false;HighActive=$false;Availability='Unknown';Administrator=$false;ModernStandby=$null;CanApply=$false;CanRestore=$false;Pending=$false;Historical=$false;BackupIssue=$null;Outcome='Read';Message='Consulta el estado antes de solicitar cambios.';Plans=@();Choices=@();RequiresSelection=$false;RequiresCreation=$false;SelectionActive=$false}
}
function Set-JunoPowerBackupFailure($view,[Exception]$failure) {
    $code=Get-JunoBackupFailureCode $failure;if($null -eq $code){$code='InvalidBackup'}
    $view.BackupIssue=$code;$view.CanApply=$false;$view.CanRestore=$false;$view.Outcome='Failed'
    $view.Message='Cambios y restauración bloqueados. '+(Get-JunoBackupFailureText $code)
}
function Get-JunoPowerView {
    Assert-JunoLease
    $view=New-JunoPowerView
    try {
        $active=Get-ActivePlan;Assert-JunoGuid $active.Guid
        $view.ActiveGuid=$active.Guid.ToLowerInvariant();$view.ActiveName=$active.Text
        $inventory=@(Get-JunoPowerInventory)
        $plans=@($inventory|ForEach-Object{$_.Guid})
        if($plans.Count -eq 0 -or $plans -notcontains $view.ActiveGuid){throw 'Listado incompleto o plan activo cambiado; vuelve a consultar.'}
        $view.Plans=$plans
        $view.ActiveName=@($inventory|Where-Object{$_.Guid -eq $view.ActiveGuid})[0].Name
        $view.Administrator=Test-JunoAdmin
        $view.ModernStandby=Get-JunoPowerCapabilities
        if($view.ModernStandby -isnot [bool]){throw 'No se pudo determinar la compatibilidad de energía.'}
    } catch {$view.Outcome='Failed';$view.Message='No se pudo completar la consulta de energía. No se habilitan cambios. '+$_.Exception.Message;return $view}
    try {
        $backup=Get-JunoPowerBackup
        $machinePath=Get-JunoStorePath Power Machine
        # Consultar no importa ni reescribe históricos. La importación sigue siendo del motor.
        if(-not (Test-Path -LiteralPath $machinePath)) {
            $legacy=Get-JunoMachineLegacy Power
            if($null -ne $legacy){$backup=$legacy.Data;$view.Historical=$true}
        }
        $view.CanRestore=($null -ne $backup.PowerScheme)
        $transaction=$null
        if($backup.PSObject.Properties.Name -contains 'Transaction'){$transaction=$backup.Transaction}
        $view.Historical=($view.CanRestore -and $null -eq $transaction)
        if($null -ne $transaction) {
            $view.Pending=($null -ne $transaction.Pending -or $transaction.Phase -in @('Applying','Restoring'))
            if($null -ne $backup.PowerScheme -and $view.ActiveGuid -ine $transaction.Confirmed -and $view.ActiveGuid -ine $transaction.Pending) {
                $view.Outcome='Conflict';$view.CanRestore=$false;$view.Message='Conflicto: el plan cambió fuera de JUNO. Se conserva el respaldo; no se sobrescribe.';return $view
            }
        }
        $choice=Resolve-JunoPowerTarget $inventory $backup $view.ActiveGuid $null
        $view.HighActive=$choice.High
        $view.HighAvailable=(@($inventory|Where-Object{$_.Guid -eq $script:HighPerformanceGuid}).Count -gt 0 -or
            ($null -ne $transaction -and $plans -contains $backup.CreatedPowerScheme))
        $view.RequiresSelection=$choice.NeedsSelection;$view.RequiresCreation=$choice.Create
        $view.Choices=@($choice.Choices|ForEach-Object{[pscustomobject]@{Guid=$_.Guid;Name=$_.Name}})
        $view.SelectionActive=($null -ne $backup.PowerScheme -and $null -ne $transaction -and $transaction.Phase -eq 'Applied' -and $view.ActiveGuid -ieq $transaction.Confirmed)
        $view.Availability=if($choice.NeedsSelection){'ChoiceRequired'}elseif($choice.Create){'Missing'}else{'Available'}
        $view.Message=if($choice.High){'Ya estás utilizando Alto rendimiento.'}elseif($choice.NeedsSelection){'Hay planes existentes por identificar. Elige uno; el nombre no acredita equivalencia técnica. No se creará otro automáticamente.'}elseif($choice.Create){'No hay un plan reutilizable identificado. Crear el oficial requiere una confirmación explícita.'}else{'Plan identificado disponible para activar.'}
        if($view.SelectionActive -and -not $view.HighActive){$view.Message='El plan elegido está activo. Se conserva el original para restaurar.'}
        if($null -ne $backup.CreatedPowerScheme -and $plans -notcontains $backup.CreatedPowerScheme.ToLowerInvariant()) {
            $view.Message+=' El plan creado anteriormente ya no existe; el motor conserva su GUID para un reintento seguro.'
        }
        if($view.CanRestore -and $plans -notcontains $backup.PowerScheme.ToLowerInvariant()) {
            $view.CanRestore=$false;$view.Message+=' El plan original no existe; restauración bloqueada. Se conserva el respaldo.'
        }
        $view.CanApply=(-not $view.HighActive -and -not $view.SelectionActive)
        if($view.Pending){$view.CanApply=$false;$view.Message+=' Operación pendiente: consulta o restaura para reconciliar el diario.'}
        if($view.Historical){$view.Message+=' Respaldo histórico: se exige revisión adicional antes de utilizarlo.'}
        if($view.ModernStandby) {
            $view.Availability='Unsupported';$view.CanApply=$false;$view.CanRestore=$false
            $view.Message+=' Modern Standby: Alto rendimiento y restauración automática bloqueados por compatibilidad. Revisa los planes en Windows.'
        }
        if(-not $view.Administrator) {
            $view.CanApply=$false;$view.CanRestore=$false
            $view.Message+=' Requiere administrador para cambios y respaldo Machine. No hay elevación automática; abre JUNO manualmente con la misma cuenta y verifica nuevamente.'
        }
        if($script:JunoLease.Abandoned){$view.Message='Sesión anterior interrumpida; revisa el diario. '+$view.Message}
    } catch {Set-JunoPowerBackupFailure $view $_.Exception}
    return $view
}
function Invoke-JunoPowerRequest {
    param([ValidateSet('Read','Apply','Restore')][string]$Action,[switch]$Confirmed,[string]$TargetGuid=$null,[switch]$AllowCreate)
    if($Action -ne 'Read' -and -not $Confirmed) {
        $view=New-JunoPowerView;$view.Outcome='Cancelled';$view.Message='Solicitud sin confirmación. No se inició ninguna escritura.';return $view
    }
    $owned=$false
    try {
        Enter-JunoLease;$owned=$true
        $view=Get-JunoPowerView
        if($Action -eq 'Read'){return $view}
        if($Action -eq 'Apply' -and $view.HighActive -and -not $view.Pending -and $view.Outcome -eq 'Read') {
            $view.Outcome='Unchanged';$view.Message='Ya estás utilizando Alto rendimiento.';return $view
        }
        if($Action -eq 'Apply' -and $view.SelectionActive -and -not $view.Pending -and $view.Outcome -eq 'Read' -and
            ([string]::IsNullOrWhiteSpace($TargetGuid) -or $TargetGuid -ieq $view.ActiveGuid)) {
            $view.Outcome='Unchanged';$view.Message='El plan elegido ya está activo. No se realizaron modificaciones.';return $view
        }
        $allowed=if($Action -eq 'Restore'){$view.CanRestore}else{$view.CanApply}
        if(-not $allowed){if($view.Outcome -eq 'Read'){$view.Outcome='Failed'};return $view}
        $expected=$view.ActiveGuid
        if($Action -eq 'Apply') {
            $inventory=@(Get-JunoPowerInventory);$backup=Get-JunoPowerBackup
            $choice=Resolve-JunoPowerTarget $inventory $backup $view.ActiveGuid $TargetGuid
            if($choice.NeedsSelection){$view.Outcome='Failed';$view.Message='Elige un plan existente antes de continuar. No se creará otro.';return $view}
            if($choice.Create -and -not $AllowCreate){$view.Outcome='Failed';$view.Message='Crear un plan requiere confirmación explícita. No se creó ninguno.';return $view}
            if($choice.Already -and -not $view.Pending) {
                $view.Outcome='Unchanged'
                $view.Message=if($choice.High){'Ya estás utilizando Alto rendimiento.'}else{'El plan elegido ya está activo. No se realizaron modificaciones.'}
                return $view
            }
            $expected=$choice.Guid
            $null=Enable-HighPerformance -TargetGuid $TargetGuid -AllowCreate:$AllowCreate
        } else {$null=Restore-PowerPlan}
        $after=Get-JunoPowerView
        if($after.Outcome -in @('Failed','Conflict') -or $after.Pending -or
            ($Action -eq 'Apply' -and (($null -ne $expected -and $after.ActiveGuid -ine $expected) -or ($null -eq $expected -and -not $after.HighActive))) -or ($Action -eq 'Restore' -and $after.CanRestore)) {
            if($after.Outcome -ne 'Conflict'){$after.Outcome='Failed'}
            $after.Message='No se pudo confirmar la verificación final. '+$after.Message;return $after
        }
        $after.Outcome=if($Action -eq 'Restore'){'Restored'}else{'Applied'}
        $after.Message='Plan activo verificado. Puedes actualizar manualmente Información del sistema. '+$after.Message
        return $after
    } catch {
        $failure=$_.Exception;$view=New-JunoPowerView
        if($owned){try{$view=Get-JunoPowerView}catch{}}
        if($null -ne (Get-JunoBackupFailureCode $failure)){Set-JunoPowerBackupFailure $view $failure;return $view}
        if($null -ne $view.BackupIssue){return $view}
        $view.Outcome=if($failure.GetBaseException() -is [OperationCanceledException]){'Cancelled'}elseif($failure.Message -match '(?i)recurso ocupado'){'Busy'}elseif($failure.Message -match '(?i)conflicto'){'Conflict'}else{'Failed'}
        $view.Message='Operación no confirmada. Se conservan el original y cualquier diario pendiente. '+$failure.Message
        return $view
    } finally {if($owned){Exit-JunoLease}}
}
