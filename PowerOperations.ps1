#requires -Version 5.1
# Fronteras compartidas e identificación conservadora de planes existentes.
$script:HighPerformanceGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

function Get-GuidFromText([string]$text) {
    $match = [regex]::Match($text, $script:GuidPattern)
    if ($match.Success) { return $match.Value.ToLowerInvariant() }
    return $null
}

function Invoke-PowerCfg([string[]]$arguments) {
    $result = & (Get-JunoSystemTool 'powercfg.exe') @arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw ("Powercfg no pudo ejecutar '{0}': {1}" -f ($arguments -join ' '), $result.Trim())
    }
    return $result
}

function Get-ActivePlan {
    $text = Invoke-PowerCfg @('/getactivescheme')
    $guid = Get-GuidFromText $text
    if (-not $guid) { throw 'No se pudo reconocer el identificador del plan activo.' }
    return @{ Guid=$guid; Text=$text.Trim() }
}

function Get-JunoPowerInventory {
    $list=Invoke-PowerCfg @('/list')
    $result=@();$seen=@{}
    foreach($line in ($list -split '\r?\n')) {
        $matches=[regex]::Matches($line,$script:GuidPattern)
        if($matches.Count -eq 0){continue}
        if($matches.Count -ne 1){throw 'Enumeración de planes ambigua. Abre las opciones de energía de Windows.'}
        $match=$matches[0];$guid=$match.Value.ToLowerInvariant()
        if($seen.ContainsKey($guid)){throw 'Enumeración de planes duplicada o incompleta; vuelve a consultar.'}
        $seen[$guid]=$true
        $tail=$line.Substring($match.Index+$match.Length)
        $name='Plan existente'
        if($tail -match '^\s*\((.*)\)\s*\*?\s*$' -and -not [string]::IsNullOrWhiteSpace($Matches[1])){$name=$Matches[1].Trim()}
        $result+=@([pscustomobject]@{Guid=$guid;Name=$name})
    }
    if($result.Count -eq 0 -or $result.Count -gt 256){throw 'No se pudo enumerar los planes de forma segura.'}
    return $result
}
function Resolve-JunoPowerTarget($inventory,$backup,[string]$active,[string]$selected=$null) {
    $ids=@($inventory|ForEach-Object{$_.Guid})
    if($ids -notcontains $active){throw 'Plan activo cambiado o listado incompleto. Vuelve a consultar.'}
    $knownCreated=($backup.PSObject.Properties.Name -contains 'Transaction' -and $null -ne $backup.CreatedPowerScheme)
    $high=($active -ieq $script:HighPerformanceGuid -or ($knownCreated -and $active -ieq $backup.CreatedPowerScheme))
    if(-not [string]::IsNullOrWhiteSpace($selected)) {
        Assert-JunoGuid $selected;$selected=$selected.ToLowerInvariant()
        if($ids -notcontains $selected){throw 'El plan elegido ya no existe. Vuelve a consultar y elegir; no se creará otro.'}
        return [pscustomobject]@{Guid=$selected;Create=$false;NeedsSelection=$false;Already=($active -ieq $selected);High=$high;Choices=@()}
    }
    if($high){return [pscustomobject]@{Guid=$active;Create=$false;NeedsSelection=$false;Already=$true;High=$true;Choices=@()}}
    # Un nombre no acredita equivalencia. Todo GUID personalizado es una posible reutilización
    # que exige elección explícita y que impide crear otra copia automáticamente.
    $choices=@($inventory|Where-Object{$_.Guid -notin @('381b4222-f694-41f0-9685-ff5bb260df2e','a1841308-3541-4fab-bc81-f71556f20b4a')})
    $identified=@($choices|Where-Object{$_.Guid -ieq $script:HighPerformanceGuid -or ($knownCreated -and $_.Guid -ieq $backup.CreatedPowerScheme)})
    if($choices.Count -eq 1 -and $identified.Count -eq 1){return [pscustomobject]@{Guid=$identified[0].Guid;Create=$false;NeedsSelection=$false;Already=$false;High=$false;Choices=$choices}}
    if($choices.Count -gt 0){return [pscustomobject]@{Guid=$null;Create=$false;NeedsSelection=$true;Already=$false;High=$false;Choices=$choices}}
    return [pscustomobject]@{Guid=$null;Create=$true;NeedsSelection=$false;Already=$false;High=$false;Choices=@()}
}

function Enable-HighPerformance([string]$TargetGuid=$null,[switch]$AllowCreate) { Invoke-JunoPower $false $TargetGuid ([bool]$AllowCreate) }

function Restore-PowerPlan { Invoke-JunoPower $true }
