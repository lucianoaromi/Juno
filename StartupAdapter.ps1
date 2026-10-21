#requires -Version 5.1
# Presentación y revalidación de selección. Solo el motor estable escribe StartupApproved.
function New-JunoStartupView {
    [pscustomobject]@{Entries=@();Outcome='Read';Message='Consultá la lista para continuar.';Details='';CanRestore=$false;Pending=$false;Historical=$false;BackupIssue=$null;Remaining=0}
}
function Get-JunoStartupApprovalToken($snapshot) {
    Get-StartupHash ("$([bool]$snapshot.Exists)|$($snapshot.Data)")
}
function Get-JunoStartupPolicy($entry) {
    # Un nombre puede aumentar la cautela, pero nunca acredita que sea opcional.
    $evidence=([Environment]::ExpandEnvironmentVariables([string]$entry.Command))+' '+$entry.Publisher
    $all="$($entry.Name) $evidence"
    $system=[Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $systemCommand=($system -and $evidence.IndexOf($system+'\',[StringComparison]::OrdinalIgnoreCase) -ge 0)
    if($systemCommand -or $all -match '(?i)(defender|securityhealth|antivir|malwarebytes|kaspersky|eset|bitdefender|sophos|crowdstrike|sentinelone|firewall|realtek|synaptics|touchpad|fingerprint|biometric|intel|nvidia|radeon|driver)') {
        return [pscustomobject]@{Blocked=$true;Review=$false;Reason='Puede ser un componente de seguridad, hardware o del sistema. Administralo desde Windows.'}
    }
    if($entry.Recommendation -eq 'Mantener / revisar' -or $all -match '(?i)(backup|respaldo|onedrive|dropbox|icloud|google\s?drive|sync|vpn|wireguard|openvpn|logitech|logioptions|\bamd\b)') {
        return [pscustomobject]@{Blocked=$false;Review=$true;Reason='Puede afectar protección, hardware, respaldos o sincronización. Revisá si lo necesitás al iniciar Windows.'}
    }
    $optional=($entry.Recommendation -eq 'Opcional' -and $entry.SourceType -eq 'Registro' -and $evidence -match '(?i)(spotify|discord|steam|epicgameslauncher|epic games launcher|battle\.net|ubisoft connect|gog galaxy|riot client)')
    [pscustomobject]@{Blocked=$false;Review=(-not $optional);Reason=$(if($optional){''}else{'Comprobá que esta aplicación no sea necesaria para tu equipo antes de cambiar su inicio.'})}
}
function Get-JunoStartupView {
    Assert-JunoLease
    $view=New-JunoStartupView
    $view.Message='Entradas clásicas detectadas. Otras aplicaciones o entradas no legibles pueden no aparecer.'
    try{
        $backup=Get-StartupBackup;Assert-JunoStartupData $backup;$view.Remaining=@($backup.Entries).Count;$view.CanRestore=($view.Remaining -gt 0)
        # Un pendiente también importa si su origen ya no aparece en el inventario.
        foreach($record in $backup.Entries){
            if($record.PSObject.Properties.Name -notcontains 'Transaction'){$view.Historical=$true;if($record.LastWrittenData){$view.Pending=$true}}
            elseif($null -ne $record.Transaction.Pending){$view.Pending=$true}
        }
    }
    catch{
        $view.BackupIssue=Get-JunoBackupFailureCode $_.Exception
        if(-not $view.BackupIssue){$view.BackupIssue='InvalidBackup'}
        $view.Outcome='Failed';$view.Message='No se pudo validar el respaldo. Los cambios están bloqueados.'
        $view.Details=$_.Exception.ToString();$backup=[pscustomobject]@{Entries=@()}
    }
    $entries=@(Get-StartupEntries | Sort-Object Name,Scope,Id)
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $diagnostics=New-Object 'System.Collections.Generic.List[string]'
    foreach($entry in $entries) {
        $name=([regex]::Replace([string]$entry.Name,'[\p{Cc}\p{Cf}]',' ')).Trim();if($name.Length -gt 100){$name=$name.Substring(0,100)+'…'}
        $row=[pscustomobject]@{Id=$entry.Id;Name=$name;State='Unknown';Scope=$entry.Scope;CanChange=$false;NeedsReview=$false;Reason='Entrada no disponible.';Fingerprint='';ApprovalToken=''}
        try{
            Assert-JunoStartupTarget $entry
            if(@($entries|Where-Object{$_.Id -ieq $entry.Id}).Count -ne 1){throw 'Identificador duplicado; no se puede seleccionar de forma inequívoca.'}
            $fingerprint=Get-StartupSourceFingerprint $entry
            if(-not $fingerprint){throw 'La entrada original ya no existe. Actualizá la lista.'}
            if($entry.SourceType -eq 'Registro') {
                $source=Read-StartupRegValue $entry.SourceHive $entry.SourceView $entry.SourceKey $entry.SourceValue
                if(-not $source.Exists -or $source.Kind -notin @('String','ExpandString') -or [string]$source.Data -cne [string]$entry.Command -or (Get-StartupHash ("$($entry.Id)|$($source.Kind)|$($source.Data)")) -cne $fingerprint){throw 'La entrada cambió durante la consulta o tiene un formato no compatible.'}
            }
            $value=Read-StartupRegValue $entry.ApprovalHive $entry.ApprovalView $entry.ApprovalKey $entry.ApprovalValue
            $snapshot=Get-StartupApprovalSnapshot $value
            $flag=Get-StartupFlag $value
            $row.State=switch($flag){'Activo'{'Enabled'} 'Desactivado'{'Disabled'} default{'Unknown'}}
            $row.Fingerprint=$fingerprint;$row.ApprovalToken=Get-JunoStartupApprovalToken $snapshot
            $policy=Get-JunoStartupPolicy $entry
            $row.NeedsReview=$policy.Review;$row.Reason=$policy.Reason
            $row.CanChange=($entry.Editable -and $row.State -ne 'Unknown' -and -not $policy.Blocked -and -not $view.BackupIssue)
            if($row.State -eq 'Unknown'){$row.Reason='Windows devolvió un estado no reconocido. Usá Configurar en Windows.'}
            if($entry.ApprovalHive -eq 'LocalMachine' -and -not (Test-JunoAdmin)){$row.CanChange=$false;$row.Reason='Necesitás permisos de administrador para modificar esta aplicación.'}
            if($view.BackupIssue){$row.Reason=$view.Message}
            $saved=@($backup.Entries|Where-Object{$_.Id -ceq $entry.Id})
            if($saved.Count -eq 1) {
                $copy=$saved[0]|ConvertTo-Json -Depth 12|ConvertFrom-Json
                if($copy.Fingerprint -cne $fingerprint){throw 'La entrada original cambió desde el respaldo. Se conserva la copia.'}
                $historical=($copy.PSObject.Properties.Name -notcontains 'Transaction')
                Initialize-StartupTransaction $copy
                $pending=($null -ne $copy.Transaction.Pending)
                if($pending){$view.Pending=$true}
                if($historical){$view.Historical=$true}
                # Solo conciliar una COPIA para determinar elegibilidad; la consulta no guarda.
                Sync-StartupTransaction $copy $snapshot
                if($historical){$view.Historical=$true}
                if($pending){$view.Pending=$true;$row.CanChange=$false;$row.Reason='Hay un cambio pendiente. Usá Restaurar cambios para recuperarlo.'}
            }
        }catch{$row.CanChange=$false;$row.Reason='La entrada cambió o no está disponible. Actualizá la lista o revisá el diagnóstico.';$diagnostics.Add($entry.Id+': '+$_.Exception.ToString())}
        $diagnostics.Add(($entry|ConvertTo-Json -Depth 5 -Compress));$diagnostics.Add(($row|ConvertTo-Json -Depth 4 -Compress));$rows.Add($row)
    }
    $view.Entries=@($rows.ToArray())
    $view.Details+="`r`n"+($diagnostics -join "`r`n")+"`r`nRespaldo:`r`n"+($backup|ConvertTo-Json -Depth 12)
    if($view.Pending){
        foreach($row in $view.Entries){if($row.CanChange){$row.CanChange=$false;$row.Reason='Hay un cambio pendiente. Recuperalo desde Restaurar cambios antes de aplicar otro.'}}
        $view.Message='Hay cambios pendientes de recuperación. Se conservan los originales.'
    }
    return $view
}
function Invoke-JunoStartupRequest {
    param([ValidateSet('Read','Enable','Disable','Restore')][string]$Action,[string]$Id='',[string]$Fingerprint='',[string]$ApprovalToken='',[switch]$Confirmed)
    if($Action -ne 'Read' -and -not $Confirmed){$view=New-JunoStartupView;$view.Outcome='Cancelled';$view.Message='Solicitud cancelada.';return $view}
    $owned=$false
    try{
        Enter-JunoLease;$owned=$true
        $view=Get-JunoStartupView
        if($Action -eq 'Read'){return $view}
        if($view.BackupIssue){return $view}
        if($Action -eq 'Restore') {
            if(-not $view.CanRestore){$view.Outcome='Unchanged';$view.Message='No hay cambios de inicio guardados.';return $view}
            $report=Restore-StartupState
            $after=Get-JunoStartupView
            $after.Details+="`r`nResultado de restauración:`r`n"+$report
            if($after.BackupIssue){return $after}
            $after.Outcome=if($after.Remaining -gt 0){'Partial'}else{'Restored'}
            $after.Message=if($after.Remaining -gt 0){'Algunos cambios no pudieron restaurarse. Se conserva su respaldo.'}else{'Se restauraron los cambios de inicio disponibles para esta cuenta y sus permisos.'}
            return $after
        }
        $chosen=@($view.Entries|Where-Object{$_.Id -ceq $Id})
        if($chosen.Count -ne 1 -or -not $chosen[0].CanChange){$view.Outcome='Blocked';$view.Message=if($chosen.Count -eq 1){$chosen[0].Reason}else{'La entrada ya no está disponible. Actualizá la lista.'};return $view}
        if($chosen[0].Fingerprint -cne $Fingerprint -or $chosen[0].ApprovalToken -cne $ApprovalToken){$view.Outcome='Conflict';$view.Message='La entrada cambió desde la selección. Actualizá la lista.';return $view}
        if(($Action -eq 'Enable' -and $chosen[0].State -eq 'Enabled') -or ($Action -eq 'Disable' -and $chosen[0].State -eq 'Disabled')){$view.Outcome='Unchanged';$view.Message='La entrada ya tiene el estado solicitado.';return $view}
        $fresh=@(Get-StartupEntries|Where-Object{$_.Id -ceq $Id})
        if($fresh.Count -ne 1){throw 'La entrada seleccionada cambió o ya no existe.'}
        $entry=$fresh[0];Assert-JunoStartupTarget $entry
        $policy=Get-JunoStartupPolicy $entry
        if($policy.Blocked -or -not $entry.Editable){throw 'La entrada ya no admite esta operación.'}
        if($entry.ApprovalHive -eq 'LocalMachine' -and -not (Test-JunoAdmin)){throw 'Necesitás permisos de administrador para modificar esta aplicación.'}
        $approval=Get-StartupApprovalSnapshot (Read-StartupRegValue $entry.ApprovalHive $entry.ApprovalView $entry.ApprovalKey $entry.ApprovalValue)
        if((Get-JunoStartupApprovalToken $approval) -cne $ApprovalToken){throw 'La configuración seleccionada cambió.'}
        $enable=($Action -eq 'Enable')
        [void](Set-StartupState $entry $enable $Fingerprint $approval)
        $after=Get-JunoStartupView
        $result=@($after.Entries|Where-Object{$_.Id -ceq $Id})
        $expected=if($enable){'Enabled'}else{'Disabled'}
        if($after.BackupIssue -or $result.Count -ne 1 -or $result[0].State -cne $expected -or $result[0].Fingerprint -cne $Fingerprint -or -not $result[0].CanChange -or $after.Pending){throw 'No se pudo verificar el resultado completo.'}
        $after.Outcome='Applied';$after.Message=if($enable){$chosen[0].Name+' se iniciará automáticamente mediante esta entrada.'}else{$chosen[0].Name+' ya no se iniciará automáticamente mediante esta entrada.'}
        return $after
    }catch{
        $failure=$_.Exception;$view=New-JunoStartupView
        if($owned){try{$view=Get-JunoStartupView}catch{}}
        $view.Details+="`r`n"+$failure.ToString()
        $view.Outcome=if($failure.Message -match '(?i)recurso ocupado'){'Busy'}elseif($failure.Message -match '(?i)cambi|fuera de JUNO'){'Conflict'}elseif($failure.GetBaseException() -is [OperationCanceledException]){'Cancelled'}else{'Failed'}
        $view.Message=switch($view.Outcome){'Busy'{'Otra operación está en curso. Volvé a consultar.'} 'Conflict'{'La entrada cambió. Se conserva el respaldo; actualizá la lista.'} 'Cancelled'{'Solicitud cancelada.'} default{'No se pudo completar la operación. Consultá el estado; se conserva el respaldo.'}}
        return $view
    }finally{if($owned){Exit-JunoLease}}
}
