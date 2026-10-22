#requires -Version 5.1
# Funciones puras del motor clásico y proveedores ficticios; no importar su GUI ni ejecutar mantenimiento.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$diskAuditRoot=Split-Path $PSScriptRoot -Parent
$diskTokens=$null;$diskErrors=$null
$diskAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $diskAuditRoot 'Discos.ps1'),[ref]$diskTokens,[ref]$diskErrors)
if($diskErrors.Count){throw ($diskErrors.Message -join '; ')}
foreach($name in @('Get-DiskMedium','Get-DiskVolumes','Get-DiskReliability')){
    $node=$diskAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Get-CimInstance {[CmdletBinding()]param([string]$ClassName,[string]$Filter)throw 'TEST: CIM real prohibido'}
function Get-PhysicalDisk {[CmdletBinding()]param()throw 'TEST: discos físicos reales prohibidos'}
function Get-Partition {[CmdletBinding()]param([string]$DriveLetter)throw 'TEST: particiones reales prohibidas'}
function Get-Disk {[CmdletBinding()]param([int]$Number)throw 'TEST: disco real prohibido'}
function Get-StorageReliabilityCounter {[CmdletBinding()]param($Disk)throw 'TEST: contadores reales prohibidos'}
Describe 'Auditoría de discos clásicos con datos ficticios y consultas de solo lectura' {
    BeforeEach {
        $global:JunoDiskAuditPhysical=@([pscustomobject]@{SerialNumber='SERIAL-1';FriendlyName='Disco ficticio';MediaType='SSD'})
        $global:JunoDiskAuditDisk=[pscustomobject]@{SerialNumber='SERIAL-1';FriendlyName='Disco ficticio';BusType='SATA';HealthStatus='Healthy'}
        Mock Get-PhysicalDisk {$global:JunoDiskAuditPhysical}
        Mock Get-CimInstance {[pscustomobject]@{DeviceID='C:';VolumeName='Fixture';FileSystem='NTFS';Size=1000000000000;FreeSpace=200000000000}}
        Mock Get-Partition {[pscustomobject]@{DiskNumber=42}}
        Mock Get-Disk {$global:JunoDiskAuditDisk}
        Mock Get-StorageReliabilityCounter {throw [UnauthorizedAccessException]::new('Fixture: sin permisos')}
    }
    It 'reconoce <Medium> por una serie coincidente sin asumir igualdad de números de disco' -TestCases @(@{Medium='SSD'},@{Medium='HDD'},@{Medium='SCM'}) {
        param($Medium)$global:JunoDiskAuditPhysical[0].MediaType=$Medium
        (Get-DiskVolumes)[0].Media|Should Be $Medium
        Assert-MockCalled Get-Disk -Times 1 -Exactly -Scope It -ParameterFilter {$Number -eq 42}
    }
    It 'devuelve desconocido cuando no hay dispositivo físico o tipo admitido' -TestCases @(@{Mode='None'},@{Mode='Unspecified'},@{Mode='Duplicate'}) {
        param($Mode)
        switch($Mode){None{$global:JunoDiskAuditPhysical=@()}Unspecified{$global:JunoDiskAuditPhysical[0].MediaType='Unspecified'}Duplicate{$global:JunoDiskAuditPhysical+= $global:JunoDiskAuditPhysical[0]}}
        (Get-DiskVolumes)[0].Media|Should Be 'No detectado'
    }
    It 'no infiere SSD/HDD para un bus <Bus> sin asociación física' -TestCases @(@{Bus='USB'},@{Bus='Virtual'},@{Bus='File Backed Virtual'},@{Bus='Unknown'}) {
        param($Bus)$global:JunoDiskAuditDisk.BusType=$Bus;$global:JunoDiskAuditPhysical=@()
        $r=(Get-DiskVolumes)[0];$r.Bus|Should Be $Bus;$r.Media|Should Be 'No detectado'
    }
    It 'capacidad y libre proceden de CIM y no son un porcentaje de salud' {
        $r=(Get-DiskVolumes)[0];$r.Size|Should Be 1000000000000;$r.Free|Should Be 200000000000
        $r.Health|Should Be Healthy
        Assert-MockCalled Get-CimInstance -Times 1 -Exactly -Scope It -ParameterFilter {$ClassName -eq 'Win32_LogicalDisk' -and $Filter -eq 'DriveType=3'}
        Assert-MockCalled Get-StorageReliabilityCounter -Times 0 -Exactly -Scope It
    }
    It 'permisos insuficientes de Storage conservan capacidad y dejan el tipo desconocido' {
        Mock Get-Partition {throw [UnauthorizedAccessException]::new('Fixture: sin permisos')}
        $r=(Get-DiskVolumes)[0];$r.Media|Should Be 'No detectado';$r.Health|Should Be 'Sin datos';$r.Free|Should Be 200000000000
    }
    It 'una asociación de particiones ambigua no elige una unidad física' {
        Mock Get-Partition {@([pscustomobject]@{DiskNumber=42},[pscustomobject]@{DiskNumber=43})}
        $r=(Get-DiskVolumes)[0];$r.Media|Should Be 'No detectado'
        Assert-MockCalled Get-Disk -Times 0 -Exactly -Scope It
    }
    It 'un fallo de CIM no se convierte en datos ficticios' {
        Mock Get-CimInstance {throw [UnauthorizedAccessException]::new('Fixture: CIM no disponible')}
        {Get-DiskVolumes}|Should Throw
    }
    It 'los contadores no disponibles permanecen nulos' {
        $r=Get-DiskReliability $global:JunoDiskAuditDisk
        $r.Temperature|Should BeNullOrEmpty;$r.Wear|Should BeNullOrEmpty;$r.Hours|Should BeNullOrEmpty;$r.Uncorrected|Should BeNullOrEmpty
    }
    It 'las funciones de inventario no ejecutan operaciones de mantenimiento o escritores' {
        foreach($name in @('Get-DiskMedium','Get-DiskVolumes','Get-DiskReliability')){
            $body=(Get-Command $name -CommandType Function).ScriptBlock.ToString()
            $body|Should Not Match 'Start-Process|Process\]::Start|Optimize-Volume|Repair-Volume|Set-Disk|Set-Partition|Invoke-CimMethod|fsutil|defrag|chkdsk|Write-JunoStore|Invoke-JunoTrim'
        }
    }
}
