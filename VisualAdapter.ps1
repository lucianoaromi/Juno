#requires -Version 5.1
# Proyección de estados y autorización. Las escrituras pertenecen al motor compartido.
function New-JunoVisualView {
    return [pscustomobject]@{State='Unknown';Outcome='Read';Message='Estado aún no consultado.';Details='';CanApply=$false;CanRestore=$false;Pending=$false;PartialOperation=$false;Historical=$false;BackupIssue=$null}
}
function Set-JunoVisualBackupFailure($view,[Exception]$failure) {
    $code=Get-JunoBackupFailureCode $failure;if($null -eq $code){$code='InvalidBackup'}
    $view.BackupIssue=$code;$view.CanApply=$false;$view.CanRestore=$false;$view.Outcome='Failed'
    $view.Message=Get-JunoBackupFailureText $code
}
function Get-JunoVisualMode($actual) {
    # Reconocer un preset exige API y todos sus valores explícitos de Registro.
    if(Test-JunoVisualTarget $actual (Get-JunoVisualPreset $actual $true)){return 'Quality'}
    if(Test-JunoVisualTarget $actual (Get-JunoVisualPreset $actual $false)){return 'Maximum'}
    foreach($pair in @(@('FontSmoothing','FontSmoothing','2'),@('DragFullWindows','DragFullWindows','1'),@('MinAnimate','MinimizeAnimation','1'))) {
        $r=@($actual.Registry|Where-Object{$_.Name -ceq $pair[0]})[0]
        if($r.Exists -and ($r.Value -notin @('0',$pair[2]) -or ([bool]$actual.Effects.($pair[1]) -ne ($r.Value -ceq $pair[2])))){return 'Partial'}
    }
    $apiPreset=$true
    foreach($p in $actual.Effects.PSObject.Properties){if($p.Name -ne 'FontSmoothing' -and $p.Value){$apiPreset=$false}}
    if($apiPreset){return 'Partial'}
    $setting=@($actual.Registry|Where-Object{$_.Name -ceq 'VisualFXSetting'})[0]
    if($setting.Exists -and $setting.Value -ceq '0'){return 'Default'}
    return 'Custom'
}
function Get-JunoVisualView {
    Assert-JunoLease
    $view=New-JunoVisualView
    try {$actual=Get-JunoVisualState}
    catch {
        $view.Outcome='Failed';$view.Message='No se pudo consultar la configuración visual. '+$_.Exception.Message
        try{$stored=Get-Backup;$entry=$stored.Journal.Visual;$view.Pending=($null -ne $entry -and ($entry.Pending -or $entry.Phase -in @('Applying','Restoring')));$view.Details='Diario conservado: '+($entry|ConvertTo-Json -Depth 8)}catch{Set-JunoVisualBackupFailure $view $_.Exception}
        return $view
    }
    $view.State=Get-JunoVisualMode $actual
    try {$backup=Get-Backup}
    catch {Set-JunoVisualBackupFailure $view $_.Exception;return $view}
    $t=$backup.Journal.Visual
    $view.CanRestore=($null -ne $backup.VisualEffects -or $null -ne $backup.VisualRegistry)
    $view.Historical=($view.CanRestore -and $null -eq $t)
    $view.CanApply=(-not $view.Historical)
    $view.Message='Configuración consultada; ningún cambio solicitado.'
    $view.Details="Ámbito: usuario actual (HKCU). No requiere administrador.`r`nEstado consultado:`r`n"+($actual|ConvertTo-Json -Depth 8)+
        "`r`nOriginal de efectos:`r`n"+($backup.VisualEffects|ConvertTo-Json -Depth 8)+"`r`nOriginal de Registro:`r`n"+($backup.VisualRegistry|ConvertTo-Json -Depth 8)+
        "`r`nDiario visual:`r`n"+($t|ConvertTo-Json -Depth 8)+"`r`nSe mantienen independientes los datos y el diario de Transparencia. UserPreferencesMask se conserva sin interpretar sus bytes. El marcador VisualFXSetting=0 indica selección administrada por Windows, no certifica valores de fábrica. Una configuración parcial puede ajustarse solo si la consulta completa y el respaldo son válidos."
    if($null -ne $t) {
        $view.Pending=($t.Pending -or $t.Phase -in @('Applying','Restoring'))
        if(-not $t.Pending -and -not (Test-JunoEqual $actual $t.Confirmed)) {
            $view.Outcome='Conflict';$view.CanApply=$false;$view.CanRestore=$false
            $view.Message='Conflicto: los efectos cambiaron fuera de JUNO. Se conserva el respaldo.';return $view
        }
        if($view.Pending -or $t.Phase -eq 'Restoring'){$view.CanApply=$false;$view.Message='Hay un cambio pendiente de revisión.'}
        if($t.Phase -eq 'Partial'){$view.PartialOperation=$true;$view.Message='La operación anterior quedó parcialmente aplicada; se conserva el original.'}
    }
    if($view.Historical){$view.Message='Respaldo histórico: restaurar exige revisar los valores anteriores.'}
    return $view
}
function Invoke-JunoVisualRequest {
    param([ValidateSet('Read','Quality','Maximum','Restore')][string]$Action,[switch]$Confirmed)
    if($Action -ne 'Read' -and -not $Confirmed){$view=New-JunoVisualView;$view.Outcome='Cancelled';$view.Message='Solicitud sin confirmación.';return $view}
    $owned=$false
    try {
        Enter-JunoLease;$owned=$true
        Initialize-JunoVisualInterop
        $view=Get-JunoVisualView
        if($Action -eq 'Read'){return $view}
        $allowed=if($Action -eq 'Restore'){$view.CanRestore}else{$view.CanApply}
        if(-not $allowed){if($view.Outcome -eq 'Read'){$view.Outcome='Failed'};return $view}
        if($Action -ne 'Restore' -and $view.State -ceq $Action){$view.Outcome='Unchanged';$view.Message='Los efectos visuales ya están optimizados.';return $view}
        if($Action -eq 'Restore'){$message=Restore-VisualEffects}else{$message=Apply-VisualEffects ($Action -eq 'Quality')}
        $after=Get-JunoVisualView
        if($after.Outcome -in @('Failed','Conflict') -or $after.Pending -or ($Action -ne 'Restore' -and $after.State -cne $Action)){
            if($after.Outcome -ne 'Conflict'){$after.Outcome='Failed'};$after.Message='No se pudo confirmar el resultado. '+$after.Message;return $after
        }
        $after.Outcome=if($Action -eq 'Restore'){'Restored'}else{'Applied'};$after.Message=$message;return $after
    } catch {
        $failure=$_.Exception;$view=New-JunoVisualView
        if($owned){try{$view=Get-JunoVisualView}catch{}}
        if($null -ne (Get-JunoBackupFailureCode $failure)){Set-JunoVisualBackupFailure $view $failure;return $view}
        if($null -ne $view.BackupIssue){return $view}
        $view.Outcome=if($failure.GetBaseException() -is [OperationCanceledException]){'Cancelled'}elseif($failure.Message -match '(?i)conflicto'){'Conflict'}elseif($failure.Message -match '(?i)recurso ocupado'){'Busy'}else{'Failed'}
        $view.Message='No se pudo completar la operación. Se conserva el original. '+$failure.Message;return $view
    } finally {if($owned){Exit-JunoLease}}
}
