# Operaciones con diario: intencion persistida, escritura, lectura y confirmacion.
# Las funciones de frontera se sustituyen por simulaciones en las pruebas.
function Sync-JunoScalar($transaction,$actual) {
    if ($null -ne $transaction.Pending -and (Test-JunoEqual $actual $transaction.Pending)) {
        $transaction.Confirmed=Copy-JunoObject $actual
    } elseif (-not (Test-JunoEqual $actual $transaction.Confirmed)) {
        throw 'Conflicto: la configuracion cambio fuera de JUNO. No se sobrescribio; se conserva el respaldo.'
    }
    $transaction.Pending=$null
}
function Confirm-JunoUnknownState([string]$name,$current,$original) {
    Confirm-JunoReview ("Estado desconocido de ${name}: este respaldo historico o la interrupcion no permite atribuir el estado actual a JUNO. Revisa ambos valores. Continuar autoriza restaurar los originales mostrados; puede reemplazar cambios posteriores de otras herramientas.`n`nActual:`n"+($current|ConvertTo-Json -Depth 18)+"`nOriginal:`n"+($original|ConvertTo-Json -Depth 18)+"`n`n¿Autorizar esta recuperacion?")
}

function Get-JunoPowerBackup {
    return (Read-JunoStore 'Power' 'Machine' ([pscustomobject]@{PowerScheme=$null;CreatedPowerScheme=$null}))
}
function Invoke-JunoPower([bool]$restore) {
    Assert-JunoLease
    Import-JunoMachineLegacy 'Power'
    $backup=Get-JunoPowerBackup
    foreach ($n in @('PowerScheme','CreatedPowerScheme')) { if ($null -ne $backup.$n) { $backup.$n=$backup.$n.ToLowerInvariant() } }
    $before=(Get-ActivePlan).Guid; Assert-JunoGuid $before
    if ($restore -and $null -eq $backup.PowerScheme) { return 'Energia: no hay una restauracion pendiente.' }
    if ($backup.PSObject.Properties.Name -notcontains 'Transaction' -or $null -eq $backup.PowerScheme) {
        if ($null -ne $backup.PowerScheme) {
            Confirm-JunoUnknownState 'energia' $before $backup.PowerScheme
            # Un GUID historico no demuestra propiedad sobre un plan duplicado. Conservarlo en
            # history, pero no reutilizarlo como si fuera una creacion confirmada de esta version.
            $backup.CreatedPowerScheme=$null
        }
        else { $backup.PowerScheme=$before }
        $t=[pscustomobject]@{Version=1;Confirmed=$before;Pending=$null;Phase='Applying'}
        Add-Member -InputObject $backup NoteProperty Transaction $t -Force
    }
    $t=$backup.Transaction; Sync-JunoScalar $t $before
    if ($restore) {
        $target=$backup.PowerScheme; $t.Phase='Restoring'
    } else {
        if ($t.Phase -eq 'Restoring') { throw 'Energia: completa la restauracion pendiente antes de aplicar otro cambio.' }
        $plans=Invoke-PowerCfg @('/list')
        $target=$script:HighPerformanceGuid
        if ($plans -notmatch [regex]::Escape($target)) {
            if ($null -eq $backup.CreatedPowerScheme) { $backup.CreatedPowerScheme=[Guid]::NewGuid().ToString() }
            $target=$backup.CreatedPowerScheme
            Write-JunoStore 'Power' $backup 'Machine'
            # GUID elegido y respaldado antes de crear. Reintentar reutiliza el mismo identificador.
            if ($plans -notmatch [regex]::Escape($target)) {
                Invoke-PowerCfg @('/duplicatescheme',$script:HighPerformanceGuid,$target) | Out-Null
                if ((Invoke-PowerCfg @('/list')) -notmatch [regex]::Escape($target)) { throw 'Energia: no se pudo verificar la creacion del plan. Se conserva el identificador pendiente.' }
            }
        }
        $t.Phase='Applying'
    }
    Assert-JunoGuid $target
    if ($before -ine $target) {
        $t.Pending=$target; Write-JunoStore 'Power' $backup 'Machine'
        if ((Get-ActivePlan).Guid -ine $t.Confirmed) { throw 'Conflicto: cambio el plan antes de escribir. La operacion queda pendiente.' }
        Invoke-PowerCfg @('/setactive',$target) | Out-Null
        if ((Get-ActivePlan).Guid -ine $target) { throw 'Energia: no se pudo verificar el plan activo. Se conserva la operacion pendiente.' }
        $t.Confirmed=$target; $t.Pending=$null
    }
    if ($restore) { $backup.PowerScheme=$null; $t.Phase='Restored' } else { $t.Phase='Applied' }
    Write-JunoStore 'Power' $backup 'Machine'
    if ($restore) { return 'Energia: plan original restaurado y verificado. Los planes duplicados se conservan para revision manual.' }
    return "Energia: plan Alto rendimiento activado y verificado ($target)."
}

function Get-JunoVisualState {
    $effects=Copy-JunoObject (Get-CurrentEffects)
    Assert-JunoEffects $effects
    if (@($effects.PSObject.Properties).Count -ne 14) { throw 'Estado visual desconocido: no se pudieron consultar los 14 indicadores. No se aplicara un ajuste sin respaldo completo.' }
    $registry=Get-VisualRegistrySnapshot
    Assert-JunoVisualRegistry $registry
    if ($registry.Count -ne 10) { throw 'Estado visual incompleto. No se aplicara el cambio.' }
    return [pscustomobject]@{Effects=$effects;Registry=$registry}
}
function Set-JunoEffects($effects) {
    Assert-JunoEffects $effects
    $errors=New-Object 'Collections.Generic.List[string]'
    # UIEffects al final. Los respaldos historicos pueden contener un subconjunto valido.
    $props=@($effects.PSObject.Properties | Where-Object {$_.Name -ne 'UIEffects'})+@($effects.PSObject.Properties | Where-Object {$_.Name -eq 'UIEffects'})
    foreach ($p in $props) {
        $ok = switch ($p.Name) {
            'MinimizeAnimation' { Set-MinimizeAnimation $p.Value }
            'FontSmoothing' { Set-UiParamSwitch 0x004B $p.Value }
            'DragFullWindows' { Set-UiParamSwitch 0x0025 $p.Value }
            default { Set-EffectValue $script:EffectCodes[$p.Name][1] $p.Value }
        }
        if (-not $ok) { $errors.Add($p.Name) }
    }
    if ($errors.Count -gt 0) { throw "Efectos: API no confirmada para $($errors -join ', ')." }
}
function Test-JunoVisualTarget($actual,$target) {
    foreach ($p in $target.Effects.PSObject.Properties) {
        if ($actual.Effects.PSObject.Properties.Name -notcontains $p.Name -or $actual.Effects.($p.Name) -cne $p.Value) { return $false }
    }
    foreach ($r in $target.Registry) {
        $found=@($actual.Registry | Where-Object {$_.Key -ceq $r.Key -and $_.Name -ceq $r.Name})
        if ($found.Count -ne 1 -or -not (Test-JunoEqual $found[0] $r)) { return $false }
    }
    return $true
}
function Invoke-JunoVisual([bool]$restore,[bool]$keepFont=$false) {
    Assert-JunoLease
    $backup=Get-Backup
    if ($restore -and $null -eq $backup.VisualEffects -and $null -eq $backup.VisualRegistry) { return 'Efectos: no hay una restauracion pendiente.' }
    $before=Get-JunoVisualState
    $t=$backup.Journal.Visual
    if ($null -eq $t -and ($null -ne $backup.VisualEffects -or $null -ne $backup.VisualRegistry)) {
        if (-not $restore) { throw 'Hay un respaldo visual historico pendiente. Restauralo antes de aplicar otro cambio.' }
        Confirm-JunoUnknownState 'efectos visuales' $before ([pscustomobject]@{Effects=$backup.VisualEffects;Registry=$backup.VisualRegistry})
    } elseif ($null -ne $t) {
        if ($t.Pending) {
            if (-not $restore) { throw 'Estado visual desconocido tras una interrupcion. Usa Restaurar para revisar la recuperacion.' }
            Confirm-JunoUnknownState 'efectos visuales interrumpidos' $before ([pscustomobject]@{Effects=$backup.VisualEffects;Registry=$backup.VisualRegistry})
        } elseif (-not (Test-JunoEqual $before $t.Confirmed)) { throw 'Conflicto: los efectos cambiaron fuera de JUNO. No se sobrescribieron.' }
        if ($t.Phase -eq 'Restoring' -and -not $restore) { throw 'Completa primero la restauracion visual pendiente.' }
    }
    if ($null -eq $backup.VisualEffects -and $null -eq $backup.VisualRegistry) {
        $backup.VisualEffects=Copy-JunoObject $before.Effects; $backup.VisualRegistry=Copy-JunoObject $before.Registry
    }
    $target=[pscustomobject]@{Effects=[pscustomobject]@{};Registry=@()}
    if ($restore) {
        if ($null -ne $backup.VisualEffects) { $target.Effects=Copy-JunoObject $backup.VisualEffects }
        if ($null -ne $backup.VisualRegistry) { $target.Registry=Copy-JunoObject $backup.VisualRegistry }
    } else {
        $target=Copy-JunoObject $before
        foreach ($p in $target.Effects.PSObject.Properties) { $p.Value=$false }; $target.Effects.FontSmoothing=$keepFont
        # SPI modifica UserPreferencesMask como efecto lateral. No predecir bytes internos de Windows.
        $target.Registry=@($target.Registry | Where-Object {$_.Name -ne 'UserPreferencesMask'})
        foreach ($r in $target.Registry) {
            $r.Exists=$true
            $r.Kind=if($r.Name -in @('DragFullWindows','FontSmoothing','MinAnimate')){'String'}else{'DWord'}
            $r.Value=switch($r.Name){'IconsOnly'{'1'} 'VisualFXSetting'{if($keepFont){'3'}else{'2'}} 'FontSmoothing'{if($keepFont){'2'}else{'0'}} default{'0'}}
        }
    }
    $t=[pscustomobject]@{Confirmed=(Copy-JunoObject $before);Pending=$true;Phase=$(if($restore){'Restoring'}else{'Applying'})}
    $backup.Journal.Visual=$t
    Save-Backup $backup
    if (-not (Test-JunoEqual (Get-JunoVisualState) $before)) { throw 'Conflicto: los efectos cambiaron antes de escribir. Se conserva la operacion pendiente.' }
    $failure=$null
    try { Set-JunoEffects $target.Effects; Restore-VisualRegistry $target.Registry }
    catch { $failure=$_.Exception.Message }
    # Si ni siquiera se puede leer, mantener Pending; la proxima restauracion exige revision.
    $after=Get-JunoVisualState
    $t.Confirmed=Copy-JunoObject $after; $t.Pending=$false
    if ($null -ne $failure -or -not (Test-JunoVisualTarget $after $target)) {
        $t.Phase='Partial'; Save-Backup $backup
        throw "Operacion visual parcialmente aplicada o no confirmada. Se conserva el original para reintentar. $failure"
    }
    if ($restore) { $backup.VisualEffects=$null; $backup.VisualRegistry=$null; $backup.Journal.Visual=$null }
    else { $t.Phase='Applied' }
    Save-Backup $backup
    if ($restore) { return 'Efectos: valores originales restaurados y verificados. Algunos cambios visibles requieren cerrar sesion.' }
    return 'Efectos: ajuste registrado y verificado. Algunos cambios visibles requieren cerrar sesion.'
}

function Set-JunoTransparencySnapshot($target) {
    Assert-JunoVisualSnapshot $target -Transparency
    if ($target.Exists) { Set-RegistryVisual $script:TransparencyKey 'EnableTransparency' $target.Value 'DWord' }
    else {
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:TransparencyKey,$true)
        try { if ($null -ne $key) { $key.DeleteValue('EnableTransparency',$false) } } finally { if($key){$key.Dispose()} }
    }
}
function Invoke-JunoTransparency([bool]$restore,[bool]$enabled=$false) {
    Assert-JunoLease
    $backup=Get-Backup
    if ($restore -and $null -eq $backup.TransparencyBackup) { return 'Transparencia: no hay una restauracion pendiente.' }
    $before=Get-TransparencySnapshot; Assert-JunoVisualSnapshot $before -Transparency
    $t=$backup.Journal.Transparency
    if ($null -eq $t) {
        if ($null -ne $backup.TransparencyBackup) { Confirm-JunoUnknownState 'transparencia' $before $backup.TransparencyBackup }
        else { $backup.TransparencyBackup=Copy-JunoObject $before }
        $t=[pscustomobject]@{Confirmed=(Copy-JunoObject $before);Pending=$null;Phase='Applying'}
        $backup.Journal.Transparency=$t
    } else { Sync-JunoScalar $t $before }
    if ($t.Phase -eq 'Restoring' -and -not $restore) { throw 'Completa primero la restauracion de transparencia.' }
    $target=if($restore){$backup.TransparencyBackup}else{[pscustomobject]@{Exists=$true;Kind='DWord';Value=[string][int]$enabled}}
    $t.Phase=if($restore){'Restoring'}else{'Applying'}
    if (-not (Test-JunoEqual $before $target)) {
        $t.Pending=Copy-JunoObject $target; Save-Backup $backup
        if (-not (Test-JunoEqual (Get-TransparencySnapshot) $t.Confirmed)) { throw 'Conflicto: cambio la transparencia antes de escribir.' }
        Set-JunoTransparencySnapshot $target
        if (-not (Test-JunoEqual (Get-TransparencySnapshot) $target)) { throw 'Transparencia no confirmada: se conserva la operacion pendiente.' }
        $t.Confirmed=Copy-JunoObject $target; $t.Pending=$null
    }
    if ($restore) { $backup.TransparencyBackup=$null; $backup.Journal.Transparency=$null } else { $t.Phase='Applied' }
    Save-Backup $backup
    [void](Notify-TransparencyChange)
    if ($restore) { return 'Transparencia: original (o ausencia) restaurado y verificado en el Registro.' }
    return 'Transparencia: cambio verificado en el Registro. Algunas superficies requieren cerrar sesion.'
}

function Open-JunoPolicyKey([bool]$write) {
    $view=if([Environment]::Is64BitOperatingSystem){[Microsoft.Win32.RegistryView]::Registry64}else{[Microsoft.Win32.RegistryView]::Default}
    $root=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
    try { if($write){return $root.CreateSubKey('SOFTWARE\Policies\Microsoft\Windows\AppPrivacy')}; return $root.OpenSubKey('SOFTWARE\Policies\Microsoft\Windows\AppPrivacy',$false) }
    finally { $root.Dispose() }
}
function Get-JunoPolicyState {
    $key=Open-JunoPolicyKey $false
    $result=[pscustomobject]@{}
    try {
        foreach($spec in @(@('Deny','LetAppsRunInBackground_ForceDenyTheseApps'),@('Allow','LetAppsRunInBackground_ForceAllowTheseApps'),@('UserControl','LetAppsRunInBackground_UserInControlOfTheseApps'),@('Global','LetAppsRunInBackground'))) {
            $exists=$null -ne $key -and $key.GetValueNames() -contains $spec[1]
            $value=$null
            if ($exists) {
                $kind=if($spec[0] -eq 'Global'){'DWord'}else{'MultiString'}
                if($key.GetValueKind($spec[1]).ToString() -cne $kind){throw 'Directiva con tipo desconocido; no se modificara.'}
                $value=$key.GetValue($spec[1],$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if($spec[0] -ne 'Global'){$value=@($value)}
            }
            $snap=[pscustomobject]@{Exists=[bool]$exists;Value=$value}
            Assert-JunoValueSnapshot $snap $(if($spec[0] -eq 'Global'){'Global'}else{'Deny'})
            Add-Member -InputObject $result NoteProperty $spec[0] $snap
        }
    } finally {if($key){$key.Dispose()}}
    return $result
}
function Set-JunoPolicyValue([string]$field,$target) {
    if($field -cnotin @('Deny','Global')){throw 'Destino de directiva no permitido.'}
    Assert-JunoValueSnapshot $target $field
    $name=if($field -eq 'Deny'){'LetAppsRunInBackground_ForceDenyTheseApps'}else{'LetAppsRunInBackground'}
    $key=Open-JunoPolicyKey $true
    if($null -eq $key){throw 'No se pudo abrir AppPrivacy.'}
    try {
        if(-not $target.Exists){$key.DeleteValue($name,$false)}
        elseif($field -eq 'Deny'){$key.SetValue($name,[string[]]$target.Value,[Microsoft.Win32.RegistryValueKind]::MultiString)}
        else{$key.SetValue($name,[int]$target.Value,[Microsoft.Win32.RegistryValueKind]::DWord)}
    } finally {$key.Dispose()}
}
function Sync-JunoPolicy($backup,$actual) {
    $t=$backup.Transaction
    foreach($n in @('Allow','UserControl')){if(-not(Test-JunoEqual $actual.$n $t.Guard.$n)){throw 'Conflicto: otra herramienta cambio las listas de permiso o control de usuario.'}}
    foreach($n in @('Deny','Global')){
        $pending=$null -ne $t.Pending -and $t.Pending.Field -ceq $n -and (Test-JunoEqual $actual.$n $t.Pending.Target)
        if(-not $pending -and -not(Test-JunoEqual $actual.$n $t.Confirmed.$n)){throw 'Conflicto: la directiva cambio fuera de JUNO.'}
    }
    if($null -ne $t.Pending){$n=$t.Pending.Field; if(Test-JunoEqual $actual.$n $t.Pending.Target){$t.Confirmed.$n=Copy-JunoObject $actual.$n};$t.Pending=$null}
}
function Write-JunoPolicyStep($backup,[string]$field,$target) {
    $state=Get-JunoPolicyState; Sync-JunoPolicy $backup $state
    if(Test-JunoEqual $state.$field $target){return}
    $t=$backup.Transaction; $t.Pending=[pscustomobject]@{Field=$field;Target=(Copy-JunoObject $target)}
    Write-BPPBackup $backup
    $before=Get-JunoPolicyState
    foreach($n in @('Deny','Global')){if(-not(Test-JunoEqual $before.$n $t.Confirmed.$n)){throw 'Conflicto: la directiva cambio antes de escribir.'}}
    foreach($n in @('Allow','UserControl')){if(-not(Test-JunoEqual $before.$n $t.Guard.$n)){throw 'Conflicto: la directiva cambio antes de escribir.'}}
    Set-JunoPolicyValue $field $target
    $after=Get-JunoPolicyState
    if(-not(Test-JunoEqual $after.$field $target)){throw 'Directiva no confirmada; se conserva la operacion pendiente.'}
    $t.Confirmed.$field=Copy-JunoObject $target; $t.Pending=$null
    Write-BPPBackup $backup
}
function Invoke-JunoPolicy([string[]]$families,[bool]$restore) {
    Assert-JunoLease
    if($families.Count -eq 0){return 'No hay aplicaciones seleccionadas.'}
    foreach($family in $families){Assert-JunoFamily $family}
    $null=Confirm-BPPWrite $restore
    Import-JunoMachineLegacy 'Policy'
    $backup=Read-BPPBackup; $state=Get-JunoPolicyState
    Assert-BPPPolicyOwnership $backup $state -Request:(-not $restore)
    if($backup.PSObject.Properties.Name -notcontains 'Transaction' -or $backup.Transaction.Phase -eq 'Restored'){
        $original=[pscustomobject]@{Deny=(Copy-JunoObject $state.Deny);Global=(Copy-JunoObject $state.Global)}
        if($backup.Owned.Count -gt 0 -or $backup.MadeGlobal){
            # El formato anterior no registra presencia de una lista vacia: la revision lo explica.
            $remaining=@($state.Deny.Value|Where-Object{$backup.Owned -notcontains $_})
            $original.Deny=[pscustomobject]@{Exists=($remaining.Count -gt 0);Value=$(if($remaining.Count -gt 0){$remaining}else{$null})}
            if($backup.MadeGlobal){$original.Global=[pscustomobject]@{Exists=$false;Value=$null}}
            Confirm-JunoUnknownState 'directiva historica (la existencia de una lista vacia no fue registrada por la version anterior)' $state $original
        }
        $t=[pscustomobject]@{Version=1;Phase='Applying';Original=$original;Confirmed=[pscustomobject]@{Deny=(Copy-JunoObject $state.Deny);Global=(Copy-JunoObject $state.Global)};Pending=$null;Guard=[pscustomobject]@{Allow=(Copy-JunoObject $state.Allow);UserControl=(Copy-JunoObject $state.UserControl)}}
        Add-Member -InputObject $backup NoteProperty Transaction $t -Force
    }
    Sync-JunoPolicy $backup $state; $t=$backup.Transaction
    if($restore){
        $remove=@($families|Where-Object{$backup.Owned -contains $_}|Select-Object -Unique)
        if($remove.Count -eq 0){return 'Directiva: no hay cambios seleccionados pendientes de restaurar.'}
        $left=@($backup.Owned|Where-Object{$remove -notcontains $_})
        $targetDeny=if($left.Count -eq 0){Copy-JunoObject $t.Original.Deny}else{[pscustomobject]@{Exists=$true;Value=@($state.Deny.Value|Where-Object{$remove -notcontains $_})}}
        $t.Phase='Restoring'; Write-BPPBackup $backup
        Write-JunoPolicyStep $backup 'Deny' $targetDeny
        if($left.Count -eq 0){Write-JunoPolicyStep $backup 'Global' $t.Original.Global}
        Sync-JunoPolicy $backup (Get-JunoPolicyState)
        $backup.Owned=$left
        if($left.Count -eq 0){$backup.MadeGlobal=$false;$t.Phase='Restored'}else{$t.Phase='Applied'}
    }else{
        if($t.Phase -eq 'Restoring'){throw 'Completa la restauracion de directivas pendiente.'}
        $valid=@(Get-BPPPackages|Where-Object{$_.Compatibility -ceq 'Compatible' -and $_.Type -ceq 'UWP' -and $_.Installed -and -not $_.Protected}|ForEach-Object{$_.Family});$added=@()
        foreach($f in @($families|Select-Object -Unique)){
            if($valid -notcontains $f){throw 'La aplicacion ya no es una app opcional permitida.'}
            if($state.Allow.Value -contains $f -or $state.UserControl.Value -contains $f){throw 'Existe una directiva de permiso/control de usuario. No se sobrescribira.'}
            if($state.Deny.Value -notcontains $f -or $backup.Owned -contains $f){$added+=@($f)}
        }
        if($added.Count -eq 0){return 'Sin cambios: los bloqueos seleccionados pertenecen a otra configuracion.'}
        $backup.Owned=@($backup.Owned+$added|Select-Object -Unique);$backup.MadeGlobal=(-not $t.Original.Global.Exists)
        $t.Phase='Applying';Write-BPPBackup $backup
        if(-not $state.Global.Exists){Write-JunoPolicyStep $backup 'Global' ([pscustomobject]@{Exists=$true;Value=0})}
        Write-JunoPolicyStep $backup 'Deny' ([pscustomobject]@{Exists=$true;Value=@(@($state.Deny.Value)+$backup.Owned|Where-Object{$null -ne $_}|Select-Object -Unique)})
        Sync-JunoPolicy $backup (Get-JunoPolicyState);$t.Phase='Applied'
    }
    Write-BPPBackup $backup
    if($restore){return "Directiva: valores originales restaurados y comprobados en Registro para $($remove.Count) app(s). Permiso efectivo no verificado."}
    return "Solicitud de restriccion: escritura confirmada en Registro para $($added.Count) app(s), en todas las cuentas. Reconocimiento de politica y restriccion efectiva no verificados. Reinicia las apps y comprueba en Windows."
}

function Invoke-JunoTrimValue([int]$value) {
    Assert-JunoInt $value 0 1
    $result=(& (Join-Path $env:WINDIR 'System32\fsutil.exe') behavior set DisableDeleteNotify NTFS $value 2>&1|Out-String)
    if($LASTEXITCODE -ne 0){throw "Windows no acepto el cambio de TRIM NTFS: $result"}
}
function Invoke-JunoTrim([bool]$restore) {
    Assert-JunoLease
    if(-not(Test-JunoAdmin)){throw 'Se necesitan permisos de administrador para TRIM del equipo.'}
    Import-JunoMachineLegacy 'Trim'
    $backup=Read-JunoStore 'Trim' 'Machine' $null
    $current=(Get-DiskTrimState).State
    if($null -eq $current){throw 'Estado de TRIM desconocido; no se aplico ningun cambio.'}
    Assert-JunoInt $current 0 1
    if($restore -and $null -eq $backup){return 'TRIM: no hay una restauracion pendiente.'}
    if($restore -and $backup.PSObject.Properties.Name -contains 'Transaction' -and $backup.Transaction.Phase -eq 'Restored'){
        if($current -ne $backup.Transaction.Confirmed){throw 'Conflicto: TRIM cambio despues de la restauracion confirmada. No se sobrescribira.'}
        return 'TRIM: restauracion ya confirmada.'
    }
    if(-not $restore -and $null -eq $backup -and $current -eq 0){return 'TRIM: ya estaba permitido. No se guardo como un cambio de JUNO.'}
    if($null -eq $backup -or (-not $restore -and $backup.PSObject.Properties.Name -contains 'Transaction' -and $backup.Transaction.Phase -eq 'Restored')){
        if($current -ne 1){return 'TRIM: ya estaba permitido.'}
        $backup=[pscustomobject]@{Original=1;Date=[DateTimeOffset]::UtcNow.ToString('o');Action='NTFS DisableDeleteNotify'}
    }
    if($backup.PSObject.Properties.Name -notcontains 'Transaction'){
        # Historico: solo produjo 1 -> 0; revision explicita ya realizada al importar.
        Add-Member -InputObject $backup NoteProperty Transaction ([pscustomobject]@{Version=1;Confirmed=$current;Pending=$null;Phase='Applying'})
    }
    $t=$backup.Transaction; Sync-JunoScalar $t $current
    if($t.Phase -eq 'Restoring' -and -not $restore){throw 'Completa primero la restauracion de TRIM pendiente.'}
    $target=if($restore){1}else{0};$t.Phase=if($restore){'Restoring'}else{'Applying'}
    if($current -ne $target){
        $t.Pending=$target;Write-JunoStore 'Trim' $backup 'Machine'
        if((Get-DiskTrimState).State -ne $t.Confirmed){throw 'Conflicto: TRIM cambio antes de escribir.'}
        Invoke-JunoTrimValue $target
        if((Get-DiskTrimState).State -ne $target){throw 'TRIM no confirmado; se conserva la operacion pendiente.'}
        $t.Confirmed=$target;$t.Pending=$null
    }
    $t.Phase=if($restore){'Restored'}else{'Applied'}
    Write-JunoStore 'Trim' $backup 'Machine'
    if($restore){return 'TRIM NTFS: valor original restaurado y verificado.'}
    return 'TRIM NTFS: permitido y verificado en Windows. No demuestra soporte fisico del dispositivo.'
}
