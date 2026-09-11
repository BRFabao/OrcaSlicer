param(
    [Parameter(Mandatory = $true)]
    [int]$ParentPid,

    [Parameter(Mandatory = $true)]
    [string]$Root
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class BaleiaNativeWindow
{
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
'@

$script:BridgeRoot = Join-Path $Root 'BaleiaConnect'
$script:PendingDir = Join-Path $script:BridgeRoot 'Fila'
$script:WorkingDir = Join-Path $script:BridgeRoot 'Processando'
$script:ErrorDir = Join-Path $script:BridgeRoot 'Erros'
$script:RuntimeDir = Join-Path $script:BridgeRoot 'Runtime'
$script:LogPath = Join-Path $script:RuntimeDir 'helper.log'
$script:StopRequested = $false
$script:TrayMode = $false
$script:ConnectExecutable = $null
$script:NotifyIcon = $null

@($script:PendingDir, $script:WorkingDir, $script:ErrorDir, $script:RuntimeDir) | ForEach-Object {
    [void](New-Item -ItemType Directory -Force -Path $_)
}

function Write-BaleiaLog {
    param([string]$Message)
    try {
        $line = '{0:u} {1}' -f [DateTime]::UtcNow, $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch {}
}

function Test-BaleiaRunning {
    return [bool](Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)
}

function Get-ConnectExecutableFromRegistry {
    $registryKeys = @(
        'Registry::HKEY_CURRENT_USER\Software\Classes\bambu-connect\shell\open\command',
        'Registry::HKEY_CLASSES_ROOT\bambu-connect\shell\open\command'
    )

    foreach ($key in $registryKeys) {
        try {
            $command = (Get-Item -LiteralPath $key).GetValue('')
            if ($command -match '^\s*"([^"]+\.exe)"' -and (Test-Path -LiteralPath $Matches[1])) {
                return $Matches[1]
            }
            if ($command -match '^\s*([^\s]+\.exe)' -and (Test-Path -LiteralPath $Matches[1])) {
                return $Matches[1]
            }
        } catch {}
    }
    return $null
}

function Find-ConnectExecutable {
    $fromRegistry = Get-ConnectExecutableFromRegistry
    if ($fromRegistry) { return $fromRegistry }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Bambu Connect\Bambu Connect.exe'),
        (Join-Path $env:LOCALAPPDATA 'Bambu Connect\Bambu Connect.exe'),
        (Join-Path $env:LOCALAPPDATA 'BambuConnect\BambuConnect.exe'),
        (Join-Path $env:ProgramFiles 'Bambu Connect\Bambu Connect.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Bambu Connect\Bambu Connect.exe')
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Get-ConnectProcesses {
    $result = @()
    try {
        foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
            try {
                $titleMatch = $process.MainWindowTitle -like '*Bambu Connect*'
                $nameMatch = $process.ProcessName -match '^Bambu[ ._-]*Connect$'
                $pathMatch = $false
                if ($script:ConnectExecutable -and $process.Path) {
                    $pathMatch = [string]::Equals($process.Path, $script:ConnectExecutable, [StringComparison]::OrdinalIgnoreCase)
                }
                if ($titleMatch -or $nameMatch -or $pathMatch) { $result += $process }
            } catch {}
        }
    } catch {}
    return @($result)
}

function Get-ConnectWindow {
    foreach ($process in (Get-ConnectProcesses)) {
        try {
            $process.Refresh()
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) { return $process.MainWindowHandle }
        } catch {}
    }
    return [IntPtr]::Zero
}

function Wait-ConnectWindow {
    param([int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (-not (Test-BaleiaRunning)) { return [IntPtr]::Zero }
        $handle = Get-ConnectWindow
        if ($handle -ne [IntPtr]::Zero) { return $handle }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return [IntPtr]::Zero
}

function Ensure-ConnectRunning {
    if ((Get-ConnectProcesses).Count -gt 0) { return $true }
    try {
        if ($script:ConnectExecutable -and (Test-Path -LiteralPath $script:ConnectExecutable)) {
            Start-Process -FilePath $script:ConnectExecutable | Out-Null
        } else {
            Start-Process 'bambu-connect://' | Out-Null
        }
        return ((Wait-ConnectWindow -TimeoutSeconds 30) -ne [IntPtr]::Zero)
    } catch {
        Write-BaleiaLog ('Bambu Connect could not be opened: ' + $_.Exception.Message)
        return $false
    }
}

function Show-ConnectWindow {
    $script:TrayMode = $false
    if (-not (Ensure-ConnectRunning)) { return }
    $handle = Wait-ConnectWindow -TimeoutSeconds 10
    if ($handle -ne [IntPtr]::Zero) {
        [void][BaleiaNativeWindow]::ShowWindowAsync($handle, 9)
        [void][BaleiaNativeWindow]::SetForegroundWindow($handle)
    }
}

function Hide-ConnectWindow {
    $handle = Get-ConnectWindow
    if ($handle -ne [IntPtr]::Zero) {
        [void][BaleiaNativeWindow]::ShowWindowAsync($handle, 0)
        $script:TrayMode = $true
    }
}

function Stop-Connect {
    foreach ($process in (Get-ConnectProcesses)) {
        try {
            $process.Refresh()
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                [void][BaleiaNativeWindow]::PostMessage($process.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            } else {
                $process.CloseMainWindow() | Out-Null
            }
        } catch {}
    }
    Start-Sleep -Milliseconds 1200
    foreach ($process in (Get-ConnectProcesses)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Get-AutomationRoot {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return $null }
    try { return [System.Windows.Automation.AutomationElement]::FromHandle($Handle) } catch { return $null }
}

function Get-ElementName {
    param([System.Windows.Automation.AutomationElement]$Element)
    try { return [string]$Element.Current.Name } catch { return '' }
}

function Get-NamedElements {
    param(
        [System.Windows.Automation.AutomationElement]$RootElement,
        [string[]]$Names,
        [System.Windows.Automation.ControlType[]]$ControlTypes
    )
    $matches = @()
    if (-not $RootElement) { return $matches }
    try {
        $all = $RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($element in $all) {
            try {
                if ($ControlTypes -and $ControlTypes.Count -gt 0 -and $ControlTypes -notcontains $element.Current.ControlType) { continue }
                $name = ([string]$element.Current.Name).Trim()
                foreach ($candidate in $Names) {
                    if ([string]::Equals($name, $candidate, [StringComparison]::OrdinalIgnoreCase)) {
                        $matches += $element
                        break
                    }
                }
            } catch {}
        }
    } catch {}
    return @($matches)
}

function Invoke-AutomationElement {
    param([System.Windows.Automation.AutomationElement]$Element)
    if (-not $Element) { return $false }
    try {
        $pattern = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
        return $true
    } catch {}
    try {
        $pattern = $Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        ([System.Windows.Automation.SelectionItemPattern]$pattern).Select()
        return $true
    } catch {}
    try {
        $pattern = $Element.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern)
        ([System.Windows.Automation.LegacyIAccessiblePattern]$pattern).DoDefaultAction()
        return $true
    } catch {}
    return $false
}

function Wait-AndInvokeNamedControl {
    param(
        [string[]]$Names,
        [int]$TimeoutSeconds,
        [System.Windows.Automation.AutomationElement]$ExcludeElement = $null
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $types = @(
        [System.Windows.Automation.ControlType]::Button,
        [System.Windows.Automation.ControlType]::Hyperlink,
        [System.Windows.Automation.ControlType]::MenuItem
    )
    do {
        if (-not (Test-BaleiaRunning)) { return $null }
        $rootElement = Get-AutomationRoot (Get-ConnectWindow)
        foreach ($element in (Get-NamedElements $rootElement $Names $types)) {
            if ($ExcludeElement) {
                try {
                    if ([System.Windows.Automation.Automation]::Compare($element, $ExcludeElement)) { continue }
                } catch {}
            }
            try {
                if (-not $element.Current.IsEnabled) { continue }
            } catch { continue }
            if (Invoke-AutomationElement $element) { return $element }
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return $null
}

function Get-WindowTextSnapshot {
    $names = New-Object System.Collections.Generic.List[string]
    $rootElement = Get-AutomationRoot (Get-ConnectWindow)
    if (-not $rootElement) { return '' }
    try {
        $all = $rootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($element in $all) {
            try {
                $name = ([string]$element.Current.Name).Trim()
                if ($name) { $names.Add($name) }
            } catch {}
        }
    } catch {}
    return ($names -join "`n")
}

function Wait-PrintingEvidence {
    param([string]$DisplayName, [int]$TimeoutSeconds = 20)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (-not (Test-BaleiaRunning)) { return $false }
        $snapshot = Get-WindowTextSnapshot
        if ($snapshot -match '(?i)Printing|Imprimindo|Sending|Enviando|Uploading|Carregando') { return $true }
        if ($DisplayName -and $snapshot -match [Regex]::Escape($DisplayName) -and
            $snapshot -match '(?i)Progress|Progresso|Layer|Camada') { return $true }
        Start-Sleep -Milliseconds 400
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Invoke-ConnectPrintFlow {
    param($Manifest, [string]$GcodePath)

    if (-not (Ensure-ConnectRunning)) { throw 'Bambu Connect não foi encontrado ou não abriu.' }

    $encodedPath = [Uri]::EscapeDataString($GcodePath)
    $encodedName = [Uri]::EscapeDataString([string]$Manifest.display_name)
    $uri = 'bambu-connect://import-file?path={0}&name={1}&version=1.0.0' -f $encodedPath, $encodedName
    Start-Process $uri | Out-Null

    $handle = Wait-ConnectWindow -TimeoutSeconds 30
    if ($handle -eq [IntPtr]::Zero) { throw 'A janela do Bambu Connect não apareceu.' }
    if ($script:TrayMode) { [void][BaleiaNativeWindow]::ShowWindowAsync($handle, 0) }

    $importButton = Wait-AndInvokeNamedControl @(
        'Import', 'Import File', 'Import G-code 3MF', 'Import Gcode 3MF',
        'Importar', 'Importar arquivo', 'Aceitar', 'Confirm', 'Confirmar', 'OK'
    ) 45
    if (-not $importButton) { throw 'O botão de importação do Bambu Connect não foi localizado.' }
    Write-BaleiaLog ('Import accepted for ' + $Manifest.job_id)

    $printButton = Wait-AndInvokeNamedControl @('Print', 'Imprimir') 60
    if (-not $printButton) { throw 'O botão Print do Bambu Connect não foi localizado.' }
    Write-BaleiaLog ('Print invoked for ' + $Manifest.job_id + ' on ' + $Manifest.printer.name)

    # From this click onward Bambu Connect owns authentication, printer-busy
    # checks and the actual transport. Do not add a second guessed validation
    # layer here: the final printer and AMS choices were already made in Baleia
    # and are retained in the manifest for diagnosis.
    if (-not (Wait-PrintingEvidence ([string]$Manifest.display_name) 12)) {
        Write-BaleiaLog ('Connect accepted Print without exposing a stable progress label for ' + $Manifest.job_id)
    }
    if ($script:TrayMode) { Hide-ConnectWindow }
}

function Move-JobToError {
    param([string]$ManifestPath, [string]$GcodePath, [string]$Message)
    try {
        $baseName = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($ManifestPath))
        $targetManifest = Join-Path $script:ErrorDir ([IO.Path]::GetFileName($ManifestPath))
        Move-Item -LiteralPath $ManifestPath -Destination $targetManifest -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $GcodePath) {
            Move-Item -LiteralPath $GcodePath -Destination (Join-Path $script:ErrorDir ([IO.Path]::GetFileName($GcodePath))) -Force -ErrorAction SilentlyContinue
        }
        Set-Content -LiteralPath (Join-Path $script:ErrorDir ($baseName + '.error.txt')) -Value $Message -Encoding UTF8
    } catch {}
    Write-BaleiaLog ('Job stopped safely: ' + $Message)
    if ($script:NotifyIcon) {
        $script:NotifyIcon.BalloonTipTitle = 'Baleia Connect'
        $script:NotifyIcon.BalloonTipText = $Message
        $script:NotifyIcon.ShowBalloonTip(8000)
    }
    Show-ConnectWindow
}

function Process-NextJob {
    $next = Get-ChildItem -LiteralPath $script:PendingDir -Filter '*.job.json' -File -ErrorAction SilentlyContinue |
        Sort-Object CreationTimeUtc | Select-Object -First 1
    if (-not $next) { return }

    $workingManifest = Join-Path $script:WorkingDir $next.Name
    try {
        Move-Item -LiteralPath $next.FullName -Destination $workingManifest -ErrorAction Stop
    } catch { return }

    $gcodePath = ''
    try {
        $manifest = Get-Content -LiteralPath $workingManifest -Raw -Encoding UTF8 | ConvertFrom-Json
        $sourceGcode = [string]$manifest.file
        if (-not (Test-Path -LiteralPath $sourceGcode)) { throw 'O arquivo G-code 3MF da fila desapareceu.' }
        $gcodePath = Join-Path $script:WorkingDir ([IO.Path]::GetFileName($sourceGcode))
        Move-Item -LiteralPath $sourceGcode -Destination $gcodePath -ErrorAction Stop

        Write-BaleiaLog ('Processing ' + $manifest.job_id + ' for ' + $manifest.printer.name)
        Invoke-ConnectPrintFlow $manifest $gcodePath

        Remove-Item -LiteralPath $gcodePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $workingManifest -Force -ErrorAction SilentlyContinue
        Write-BaleiaLog ('Completed ' + $manifest.job_id)
    } catch {
        if (Test-BaleiaRunning) {
            Move-JobToError $workingManifest $gcodePath $_.Exception.Message
        }
    }
}

function Remove-StaleFiles {
    $cutoff = [DateTime]::UtcNow.AddHours(-24)
    foreach ($directory in @($script:PendingDir, $script:WorkingDir, $script:ErrorDir)) {
        Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue | Where-Object {
            $_.LastWriteTimeUtc -lt $cutoff
        } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

$createdNew = $false
$mutexName = 'Local\BaleiaConnectHelper_' + $ParentPid
$mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) { exit 0 }

try {
    $script:ConnectExecutable = Find-ConnectExecutable

    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    if ($script:ConnectExecutable) {
        try { $script:NotifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($script:ConnectExecutable) } catch {}
    }
    if (-not $script:NotifyIcon.Icon) { $script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Application }
    $script:NotifyIcon.Text = 'Baleia Orca + Bambu Connect'
    $script:NotifyIcon.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $openItem = $menu.Items.Add('Abrir Bambu Connect')
    $exitItem = $menu.Items.Add('Fechar Connect e ajudante')
    $openItem.add_Click({ Show-ConnectWindow })
    $exitItem.add_Click({ $script:StopRequested = $true })
    $script:NotifyIcon.ContextMenuStrip = $menu
    $script:NotifyIcon.add_DoubleClick({ Show-ConnectWindow })

    Write-BaleiaLog ('Helper started for Baleia PID ' + $ParentPid)
    [void](Ensure-ConnectRunning)
    $lastCleanup = [DateTime]::MinValue

    while (-not $script:StopRequested) {
        if (-not (Test-BaleiaRunning)) { break }

        $handle = Get-ConnectWindow
        if ($handle -ne [IntPtr]::Zero -and [BaleiaNativeWindow]::IsIconic($handle)) {
            Hide-ConnectWindow
        } elseif ($script:TrayMode -and $handle -ne [IntPtr]::Zero) {
            [void][BaleiaNativeWindow]::ShowWindowAsync($handle, 0)
        }

        Process-NextJob
        if (([DateTime]::UtcNow - $lastCleanup).TotalMinutes -ge 15) {
            Remove-StaleFiles
            $lastCleanup = [DateTime]::UtcNow
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 350
    }
} catch {
    Write-BaleiaLog ('Fatal helper error: ' + $_.Exception.Message)
} finally {
    Write-BaleiaLog 'Helper stopping with Baleia.'
    Stop-Connect
    if ($script:NotifyIcon) {
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
    }
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
