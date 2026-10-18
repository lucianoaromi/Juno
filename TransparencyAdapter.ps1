#requires -Version 5.1
# Adaptación de estados. Importar define funciones; no abre el Registro ni crea respaldos.
function New-JunoTransparencyView {
    return [pscustomobject]@{State='Unknown';Outcome='Read';Message='Estado aún no consultado.';CanChange=$false;CanRestore=$false;Pending=$false;Historical=$false;BackupIssue=$null}
}
function Set-JunoTransparencyBackupFailure($view,[Exception]$failure) {
    $code=Get-JunoBackupFailureCode $failure
    if($null -eq $code){$code='InvalidBackup'}
    $view.Outcome='Failed';$view.CanChange=$false;$view.CanRestore=$false;$view.BackupIssue=$code
    $view.Message='No se habilitan escrituras ni restauración. '+(Get-JunoBackupFailureText $code)
}
function Get-JunoTransparencyView {
    Assert-JunoLease
    $view=New-JunoTransparencyView
    try {$snapshot=Get-TransparencySnapshot}
    catch {
        $view.State='Unavailable';$view.Outcome='Failed';$view.Message='No se pudo leer la transparencia. '+$_.Exception.Message
        try {
            $stored=Get-Backup;$entry=$stored.Journal.Transparency
            $view.Pending=($null -ne $entry -and ($null -ne $entry.Pending -or $entry.Phase -in @('Applying','Restoring')))
        } catch {Set-JunoTransparencyBackupFailure $view $_.Exception}
        return $view
    }
    if ($snapshot.Exists -and $snapshot.Kind -ceq 'DWord' -and $snapshot.Value -ceq '1') {$view.State='Enabled'}
    elseif ($snapshot.Exists -and $snapshot.Kind -ceq 'DWord' -and $snapshot.Value -ceq '0') {$view.State='Disabled'}
    try {Assert-JunoVisualSnapshot $snapshot -Transparency}
    catch {$view.Outcome='Failed';$view.Message='Estado desconocido: el valor o tipo no es compatible. No se habilitan escrituras. '+$_.Exception.Message;return $view}
    try {$backup=Get-Backup}
    catch {Set-JunoTransparencyBackupFailure $view $_.Exception;return $view}
    $transaction=$backup.Journal.Transparency
    $view.CanChange=$true
    $view.CanRestore=($null -ne $backup.TransparencyBackup)
    $view.Historical=($view.CanRestore -and $null -eq $transaction)
    $view.Message=if($view.CanRestore){'Original conservado. La restauración está disponible en esta tarjeta.'}else{'Sin restauración pendiente. La consulta no modifica Windows ni los respaldos.'}
    if ($view.State -eq 'Unknown') {$view.Message='Valor ausente o no estándar; no se infiere el efecto visual. '+$view.Message}
    if ($view.Historical) {$view.Message='Respaldo histórico sin diario: se solicitará una revisión adicional de los valores antes de escribir.'}
    if ($null -ne $transaction) {
        $view.Pending=($null -ne $transaction.Pending -or $transaction.Phase -in @('Applying','Restoring'))
        if (-not (Test-JunoEqual $snapshot $transaction.Confirmed) -and
            -not ($null -ne $transaction.Pending -and (Test-JunoEqual $snapshot $transaction.Pending))) {
            $view.Outcome='Conflict';$view.CanChange=$false;$view.CanRestore=$false
            $view.Message='Conflicto detectado: la configuración cambió fuera de JUNO. No se sobrescribe; se conserva el respaldo.'
            return $view
        }
        if ($transaction.Phase -eq 'Restoring') {$view.CanChange=$false}
        if ($view.Pending) {$view.Message='El diario requiere reconciliación. Puedes restaurar el original; una restauración iniciada debe completarse antes de aplicar otro ajuste.'}
    }
    return $view
}
function Invoke-JunoTransparencyRequest {
    param([ValidateSet('Read','Enable','Disable','Restore')][string]$Action,[switch]$Confirmed)
    # Rechazo antes de adquirir el bloqueo o leer datos: nunca hay escritura sin autorización.
    if ($Action -ne 'Read' -and -not $Confirmed) {
        $view=New-JunoTransparencyView;$view.Outcome='Cancelled';$view.Message='Solicitud cancelada o sin confirmación. No se escribió.';return $view
    }
    $owned=$false
    try {
        Enter-JunoLease
        $owned=$true
        $view=Get-JunoTransparencyView
        if ($Action -eq 'Read') {
            if ($script:JunoLease.Abandoned) {$view.Message='Sesión anterior interrumpida. Se validó el respaldo sin modificarlo. '+$view.Message}
            return $view
        }
        $allowed=if($Action -eq 'Restore'){$view.CanRestore}else{$view.CanChange}
        if (-not $allowed) {
            if($view.Outcome -eq 'Read'){$view.Outcome='Failed'}
            return $view
        }
        # La implementación estable revalida, persiste intención, escribe, relee y confirma.
        if ($Action -eq 'Restore') {$message=Restore-Transparency}
        else {$message=Set-Transparency ($Action -eq 'Enable')}
        $after=Get-JunoTransparencyView
        if ($after.Outcome -in @('Failed','Conflict') -or $after.Pending) {
            if($after.Outcome -ne 'Conflict'){$after.Outcome='Failed'}
            $after.Message='La verificación final no permite confirmar la operación. '+$after.Message
            return $after
        }
        $after.Outcome=if($Action -eq 'Restore'){'Restored'}else{'Applied'}
        $after.Message=if($Action -eq 'Restore'){'Restauración completada: original (o ausencia) verificado en el Registro. El cambio visual puede requerir cerrar sesión manualmente.'}else{'Escritura confirmada en el Registro. El cambio visual puede estar pendiente de actualización; algunas superficies requieren cerrar sesión manualmente.'}
        return $after
    } catch {
        $failure=$_.Exception
        $cancelled=($failure.GetBaseException() -is [OperationCanceledException])
        $view=New-JunoTransparencyView
        if($owned){try{$view=Get-JunoTransparencyView}catch{}}
        if($null -ne (Get-JunoBackupFailureCode $failure)) {Set-JunoTransparencyBackupFailure $view $failure;return $view}
        if($null -ne $view.BackupIssue) {return $view}
        $view.Outcome=if($cancelled){'Cancelled'}elseif($failure.Message -match '(?i)conflicto'){'Conflict'}elseif($failure.Message -match '(?i)recurso ocupado'){'Busy'}else{'Failed'}
        if(-not $owned){$view.State='Unavailable'}
        $view.Message=if($cancelled){'Revisión cancelada. Se conservan los respaldos. '}else{'Operación no confirmada. Se conservan los respaldos y cualquier diario pendiente. '}
        $view.Message+=$failure.Message
        return $view
    } finally {if($owned){Exit-JunoLease}}
}
