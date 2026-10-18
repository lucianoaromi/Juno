#requires -Version 5.1
# Eventos reales de WinForms con inventario simulado y sin ventanas modales.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$backgroundUiRoot=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $backgroundUiRoot 'BackgroundInventory.ps1')
. (Join-Path $backgroundUiRoot 'UiSupport.ps1')
foreach($spec in @(@{File='Juno.ps1';Names=@('New-Label','New-Button')},@{File='PermisosSegundoPlano.ps1';Names=@('Show-BackgroundPermissions')})){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $backgroundUiRoot $spec.File),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw($errors.Message -join '; ')}
    foreach($name in $spec.Names){
        $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        $source=$node.Extent.Text
        if($name -eq 'Show-BackgroundPermissions'){
            $source=$source.Replace('[void]$dialog.ShowDialog($parent)','Invoke-BackgroundTestUi $dialog')
            $source=$source.Replace("[void][Windows.Forms.MessageBox]::Show(`$dialog,`$message,'Resultado de configuracion')",'Show-BackgroundTestMessage $message')
            $source=$source.Replace("[void][Windows.Forms.MessageBox]::Show(`$dialog,`$_.Exception.Message,'Operacion pendiente o fallida','OK','Warning')",'Show-BackgroundTestMessage $_.Exception.Message')
            if($source -match '\$dialog\.ShowDialog|\[Windows.Forms.MessageBox\]::Show'){throw 'TEST: ventana modal no sustituida'}
        }
        . ([scriptblock]::Create($source))
    }
}
function Invoke-BackgroundTestUi($dialog){& $global:JunoBackgroundUiAction $dialog}
function Show-BackgroundTestMessage($message){$global:JunoBackgroundUiMessage=$message}
function Invoke-BackgroundTestClick($button){[void]$button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))}
function Get-BackgroundTestGrid($form){return @($form.Controls|Where-Object{$_ -is [Windows.Forms.DataGridView]})[0]}
function Get-BackgroundTestButton($form,[string]$text){return @($form.Controls|Where-Object{$_.Text -ceq $text})[0]}
function Get-BPPPermissionView {throw 'TEST: inventario real prohibido'}
function Confirm-BPPAction([string]$action,[int]$count){throw 'TEST: confirmacion modal real prohibida'}
function Invoke-BPPSelection([string]$action,$rows,[bool]$confirmed){throw 'TEST: cambios reales prohibidos'}
function Open-BPPSettings([string]$family){throw 'TEST: abrir aplicaciones reales prohibido'}
function New-BackgroundTestRow([string]$family,[bool]$request,[bool]$restore){
    return [pscustomobject]@{Name=$family;Family=$family;Type='UWP';Classification='Compatibilidad no verificada';Configuration='Eficacia no verificada';Method='Usuario / legado';CanRequest=$request;CanRestore=$restore;Reason='Fixture sin eficacia acreditada';Requested='Ninguna'}
}
Describe 'Permisos: interfaz aislada conserva limites y restauraciones' {
    BeforeEach {
        $script:JunoIcon=$null
        $script:white=[Drawing.Color]::White;$script:muted=[Drawing.Color]::LightGray
        $script:blue=[Drawing.Color]::SteelBlue;$script:green=[Drawing.Color]::SeaGreen;$script:gray=[Drawing.Color]::Gray
        $global:JunoBackgroundUiMessage=''
        $global:JunoBackgroundUiView=[pscustomobject]@{
            Rows=@((New-BackgroundTestRow 'Contoso.Chat_testpub' $true $false),(New-BackgroundTestRow 'Uninstalled.App_testpub' $false $true),(New-BackgroundTestRow 'Unknown.App_testpub' $false $false))
            Environment=[pscustomobject]@{Reason='Administrador requerido segun el ambito'};Errors=@()
        }
        Mock Get-BPPPermissionView {$global:JunoBackgroundUiView}
        Mock Confirm-BPPAction {$false}
        Mock Invoke-BPPSelection {'Escritura confirmada; eficacia no verificada'}
        Mock Open-BPPSettings {}
    }
    It 'abrir solo consulta y deja todo sin marcar, sin acciones incompatibles' {
        $global:JunoBackgroundUiAction={param($form)
            $grid=Get-BackgroundTestGrid $form;$grid.Rows.Count|Should Be 3
            @($grid.Rows|Where-Object{$_.Cells[0].Value}).Count|Should Be 0
            $grid.Rows[2].Cells[0].ReadOnly|Should Be $true
            $grid.Rows[1].Cells[1].Value|Should Be 'Uninstalled.App_testpub'
            (Get-BackgroundTestButton $form 'Solicitar restriccion').Enabled|Should Be $false
            (Get-BackgroundTestButton $form 'Restaurar seleccionadas').Enabled|Should Be $false
            $grid.Rows[0].Cells[3].Value|Should Match 'no verificada'
        }
        Show-BackgroundPermissions $null
        Assert-MockCalled Invoke-BPPSelection -Times 0 -Exactly -Scope It
        Assert-MockCalled Open-BPPSettings -Times 0 -Exactly -Scope It
    }
    It 'cancelar no despacha la operacion seleccionada' {
        $global:JunoBackgroundUiAction={param($form)
            $grid=Get-BackgroundTestGrid $form;$grid.Rows[0].Cells[0].Value=$true
            (Get-BackgroundTestButton $form 'Solicitar restriccion').Enabled|Should Be $true
            Invoke-BackgroundTestClick (Get-BackgroundTestButton $form 'Solicitar restriccion')
        }
        Show-BackgroundPermissions $null
        Assert-MockCalled Confirm-BPPAction -Times 1 -Exactly -Scope It
        Assert-MockCalled Invoke-BPPSelection -Times 0 -Exactly -Scope It
    }
    It 'mezclar ambitos incompatibles deshabilita ambas operaciones' {
        $global:JunoBackgroundUiAction={param($form)
            $grid=Get-BackgroundTestGrid $form;$grid.Rows[0].Cells[0].Value=$true;$grid.Rows[1].Cells[0].Value=$true
            (Get-BackgroundTestButton $form 'Solicitar restriccion').Enabled|Should Be $false
            (Get-BackgroundTestButton $form 'Restaurar seleccionadas').Enabled|Should Be $false
        }
        Show-BackgroundPermissions $null
        Assert-MockCalled Invoke-BPPSelection -Times 0 -Exactly -Scope It
    }
    It 'solicitar exige confirmacion y actualiza la lista sin mantener marcas' {
        Mock Confirm-BPPAction {$true}
        $global:JunoBackgroundUiAction={param($form)
            $grid=Get-BackgroundTestGrid $form;$grid.Rows[0].Cells[0].Value=$true
            Invoke-BackgroundTestClick (Get-BackgroundTestButton $form 'Solicitar restriccion')
            @($grid.Rows|Where-Object{$_.Cells[0].Value}).Count|Should Be 0
        }
        Show-BackgroundPermissions $null
        Assert-MockCalled Invoke-BPPSelection -Times 1 -Exactly -Scope It -ParameterFilter {$action -eq 'Request' -and $confirmed -and $rows.Count -eq 1 -and $rows[0].Family -eq 'Contoso.Chat_testpub'}
        $global:JunoBackgroundUiMessage|Should Match 'eficacia no verificada'
    }
    It 'una app desinstalada con respaldo permite restaurar y no solicitar' {
        Mock Confirm-BPPAction {$true}
        $global:JunoBackgroundUiAction={param($form)
            $grid=Get-BackgroundTestGrid $form;$grid.Rows[1].Cells[0].Value=$true
            (Get-BackgroundTestButton $form 'Restaurar seleccionadas').Enabled|Should Be $true
            (Get-BackgroundTestButton $form 'Solicitar restriccion').Enabled|Should Be $false
            Invoke-BackgroundTestClick (Get-BackgroundTestButton $form 'Restaurar seleccionadas')
        }
        Show-BackgroundPermissions $null
        Assert-MockCalled Invoke-BPPSelection -Times 1 -Exactly -Scope It -ParameterFilter {$action -eq 'Restore' -and $rows[0].Family -eq 'Uninstalled.App_testpub'}
    }
    It 'un fallo se presenta y conserva la posibilidad de relectura' {
        Mock Confirm-BPPAction {$true};Mock Invoke-BPPSelection {throw 'Fixture: operacion pendiente, respaldo conservado'}
        $global:JunoBackgroundUiAction={param($form)
            (Get-BackgroundTestGrid $form).Rows[0].Cells[0].Value=$true
            Invoke-BackgroundTestClick (Get-BackgroundTestButton $form 'Solicitar restriccion')
            Invoke-BackgroundTestClick (Get-BackgroundTestButton $form 'Actualizar lista')
        }
        Show-BackgroundPermissions $null
        $global:JunoBackgroundUiMessage|Should Match 'pendiente, respaldo conservado'
        Assert-MockCalled Get-BPPPermissionView -Times 3 -Exactly -Scope It
    }
    It 'Ajustes recibe solo el PFN de la fila elegida' {
        $global:JunoBackgroundUiAction={param($form)
            $grid=Get-BackgroundTestGrid $form;$grid.Rows[1].Selected=$true
            Invoke-BackgroundTestClick (Get-BackgroundTestButton $form 'Abrir ajustes de Windows')
        }
        Show-BackgroundPermissions $null
        Assert-MockCalled Open-BPPSettings -Times 1 -Exactly -Scope It -ParameterFilter {$family -eq 'Uninstalled.App_testpub'}
    }
}
