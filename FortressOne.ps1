<#
.SYNOPSIS
    FortressOne -- a reversible Windows tuning tool for a Fortnite-only machine.

.DESCRIPTION
    Run with no arguments for the interactive menu. Every command is also
    available non-interactively for scripting; see the examples.

    DESIGN GUARANTEES
      * Nothing is changed without first reading and journaling its prior state.
      * Every tweak can be reverted, individually or all at once.
      * Nothing is injected into, hooked into, or read from the Fortnite process.
        All changes are OS-level and applied while the game is closed.
      * The protection list is a hard veto that no tier or selection can override.

.PARAMETER Diagnose
    Runs the full diagnostic suite and writes a report. Changes nothing.

.PARAMETER Apply
    Applies tweaks up to the given tier: core, aggressive, or nuclear.

.PARAMETER Revert
    Reverts tweaks. Use -All to revert everything FortressOne has ever applied.

.PARAMETER DryRun
    Shows exactly what would change without writing anything.

.EXAMPLE
    .\FortressOne.ps1
    Interactive menu.

.EXAMPLE
    .\FortressOne.ps1 -Diagnose
    Full diagnostic report. Read this before applying anything.

.EXAMPLE
    .\FortressOne.ps1 -Apply core -DryRun
    Preview the core tweak set without touching the system.

.EXAMPLE
    .\FortressOne.ps1 -Revert -All
    Undo everything.
#>

[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(ParameterSetName = 'Diagnose')]
    [switch] $Diagnose,

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateSet('core', 'aggressive', 'nuclear')]
    [string] $Apply,

    [Parameter(ParameterSetName = 'Apply')]
    [string[]] $Category,

    [Parameter(ParameterSetName = 'Revert')]
    [switch] $Revert,

    [Parameter(ParameterSetName = 'Revert')]
    [switch] $All,

    [Parameter(ParameterSetName = 'Revert')]
    [string[]] $TweakId,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Revert')]
    [switch] $DryRun,

    [Parameter(ParameterSetName = 'Status')]
    [switch] $Status,

    [switch] $NoElevate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------

function Test-FOAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-FOAdministrator)) {
    if ($NoElevate) {
        Write-Host 'FortressOne needs administrator rights to read and change system state.' -ForegroundColor Red
        exit 1
    }

    Write-Host 'Relaunching with administrator rights...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]
        if ($value -is [switch]) {
            if ($value.IsPresent) { $argList += "-$key" }
        } elseif ($value -is [array]) {
            $argList += "-$key"; $argList += ($value -join ',')
        } else {
            $argList += "-$key"; $argList += "`"$value`""
        }
    }

    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    } catch {
        Write-Host 'Elevation was declined. FortressOne cannot run without it.' -ForegroundColor Red
        exit 1
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

$Global:FO = [ordered]@{
    Version   = '1.0.0'
    AppRoot   = $PSScriptRoot
    DataRoot  = (Join-Path $env:ProgramData 'FortressOne')
    System    = $null
    StartedAt = Get-Date
}

if (-not (Test-Path -LiteralPath $Global:FO.DataRoot)) {
    New-Item -ItemType Directory -Path $Global:FO.DataRoot -Force | Out-Null
}

$modules = @(
    'src\Core\FO.Logging.psm1'
    'src\Core\FO.Journal.psm1'
    'src\Core\FO.Providers.psm1'
    'src\Core\FO.Engine.psm1'
    'src\Core\FO.Backup.psm1'
    'src\Diag\FO.Diag.System.psm1'
    'src\Diag\FO.Diag.Network.psm1'
    'src\Diag\FO.Diag.Latency.psm1'
    'src\Modules\FO.Fortnite.psm1'
    'src\Modules\FO.Debloat.psm1'
)

foreach ($module in $modules) {
    $path = Join-Path $Global:FO.AppRoot $module
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "Missing module: $path" -ForegroundColor Red
        exit 1
    }
    Import-Module $path -Force -DisableNameChecking -Global
}

Initialize-FOLogging -LogDirectory (Join-Path $Global:FO.DataRoot 'logs') | Out-Null
Initialize-FOJournal | Out-Null
Initialize-FOSystemInfo | Out-Null

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------

function Write-FOBanner {
    Write-Host ''
    Write-Host '  ###########################################################' -ForegroundColor DarkCyan
    Write-Host '  #                    F O R T R E S S  O N E               #' -ForegroundColor Cyan
    Write-Host '  #        Reversible tuning for a Fortnite-only PC         #' -ForegroundColor DarkCyan
    Write-Host '  ###########################################################' -ForegroundColor DarkCyan
    Write-Host ''
    $s = $Global:FO.System
    Write-Host "   $($s.Cpu)" -ForegroundColor DarkGray
    Write-Host "   $(($s.Gpus | Select-Object -First 1).Name)  |  $($s.RamTotalGb)GB @ $($s.RamSpeedMhz)MHz" -ForegroundColor DarkGray
    Write-Host "   $($s.OsCaption) build $($s.OsBuild)" -ForegroundColor DarkGray

    $applied = (Get-FOAppliedTweaks).Count
    Write-Host "   Tweaks currently applied: $applied" -ForegroundColor DarkGray
    Write-Host ''
}

function Write-FOResultTable {
    param([Parameter(Mandatory)] $Result)

    foreach ($row in $Result.Results) {
        $colour = switch ($row.Outcome) {
            'Applied'        { 'Green' }
            'Reverted'       { 'Green' }
            'WouldChange'    { 'Cyan' }
            'WouldRevert'    { 'Cyan' }
            'AlreadyCorrect' { 'DarkGray' }
            'Vetoed'         { 'Yellow' }
            default          { 'Red' }
        }
        Write-Host ('  {0,-16} {1}' -f $row.Outcome, $row.TweakId) -ForegroundColor $colour
        if ($row.Outcome -in @('Vetoed', 'Failed', 'RolledBack', 'PartiallyReverted')) {
            Write-Host "                   $($row.Detail)" -ForegroundColor DarkYellow
        }
    }
}

function Read-FOChoice {
    param([string] $Prompt, [string[]] $Valid)

    while ($true) {
        Write-Host ''
        $answer = (Read-Host $Prompt).Trim().ToLowerInvariant()
        if ($Valid -contains $answer) { return $answer }
        Write-Host "  Please enter one of: $($Valid -join ', ')" -ForegroundColor Yellow
    }
}

function Confirm-FOAction {
    param([string] $Message, [string] $Consequence)

    Write-Host ''
    Write-Host "  $Message" -ForegroundColor Yellow
    if ($Consequence) {
        foreach ($line in (Split-FOText -Text $Consequence -Width 68)) {
            Write-Host "  $line" -ForegroundColor DarkYellow
        }
    }
    $answer = (Read-Host "`n  Type YES to proceed").Trim()
    return ($answer -ceq 'YES')
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Invoke-FODiagnostics {
    param([switch] $SkipNetwork)

    $sections = [System.Collections.ArrayList]::new()
    $null = $sections.Add((Get-FOSystemReport))
    $null = $sections.Add((Get-FOLatencyReport))
    $null = $sections.Add((Get-FOFortniteReport))
    if (-not $SkipNetwork) {
        $null = $sections.Add((Get-FONetworkReport))
    }
    $null = $sections.Add((Get-FODebloatReport))

    $report = $sections -join ([Environment]::NewLine * 2)

    $reportDir = Join-Path $Global:FO.DataRoot 'reports'
    if (-not (Test-Path -LiteralPath $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }
    $reportPath = Join-Path $reportDir "diagnostic-$((Get-Date).ToString('yyyyMMdd-HHmmss')).txt"

    $header = @(
        "FortressOne diagnostic report",
        "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Machine  : $env:COMPUTERNAME",
        ('=' * 72), ''
    ) -join [Environment]::NewLine

    Set-Content -LiteralPath $reportPath -Value ($header + $report) -Encoding UTF8

    Write-Host $report
    Write-Host ''
    Write-Host "  Report saved to: $reportPath" -ForegroundColor Green
    return $reportPath
}

function Invoke-FOApplyTier {
    param(
        [Parameter(Mandatory)] [string] $Tier,
        [string[]] $Categories,
        [switch] $DryRun,
        [switch] $SkipConfirm
    )

    $tweaks = Get-FOTweaks -MaxTier $Tier -Category $Categories
    if ($tweaks.Count -eq 0) {
        Write-Host '  No applicable tweaks for that selection.' -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host "  $($tweaks.Count) applicable tweak(s) at tier '$Tier':" -ForegroundColor Cyan
    foreach ($tweak in $tweaks) {
        $riskColour = switch ($tweak.risk) { 'high' { 'Red' } 'medium' { 'Yellow' } default { 'DarkGray' } }
        Write-Host ('    [{0,-6}] {1,-46} {2}' -f $tweak.risk, $tweak.name, $tweak.category) -ForegroundColor $riskColour
    }

    if ($DryRun) {
        Write-Host ''
        Write-Host '  DRY RUN -- nothing will be written.' -ForegroundColor Cyan
        $result = Invoke-FOApply -Tweaks $tweaks -DryRun -Description "Dry run: $Tier"
        Write-FOResultTable -Result $result
        return $result
    }

    $highRisk = @($tweaks | Where-Object { $_.risk -eq 'high' })
    if (-not $SkipConfirm) {
        $consequence = if ($highRisk.Count -gt 0) {
            "$($highRisk.Count) of these are marked HIGH RISK and have real security or functionality costs. Read their rationale in the tweak reference before proceeding. Everything here is revertible with -Revert -All."
        } else {
            'All of these are revertible with -Revert -All.'
        }
        if (-not (Confirm-FOAction -Message "Apply $($tweaks.Count) tweak(s)?" -Consequence $consequence)) {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return
        }
    }

    New-FORestorePoint -Description "FortressOne - before $Tier tweaks" | Out-Null
    Export-FORegistryBackup -Label "before-$Tier" | Out-Null

    $result = Invoke-FOApply -Tweaks $tweaks -Description "Apply tier: $Tier"

    Write-Host ''
    Write-FOResultTable -Result $result
    Write-Host ''
    Write-Host "  Applied: $($result.Applied)  Vetoed: $($result.Vetoed)  Failed: $($result.Failed)" -ForegroundColor Cyan
    Write-Host "  Transaction: $($result.TransactionId)" -ForegroundColor DarkGray

    if ($result.RebootNeeded) {
        Write-Host ''
        Write-Host '  A RESTART IS REQUIRED for some of these to take effect.' -ForegroundColor Yellow
    }

    return $result
}

function Invoke-FODeviceTweaks {
    Write-Host ''
    Write-Host '  Scanning for MSI-capable devices and USB power management...' -ForegroundColor Cyan

    $msiDevices = @(Get-FOMsiCapableDevices | Where-Object { -not $_.MsiEnabled })
    $usbDevices = @(Get-FOUsbPowerDevices | Where-Object { $_.EnhancedPm -eq 1 -or $_.SelectiveSuspend -eq 1 })

    $synthetic = [System.Collections.ArrayList]::new()

    if ($msiDevices.Count -gt 0) {
        Write-Host ''
        Write-Host "  MSI mode can be enabled on $($msiDevices.Count) device(s):" -ForegroundColor Cyan
        foreach ($d in $msiDevices) { Write-Host "    - $($d.FriendlyName)" -ForegroundColor DarkGray }
        $null = $synthetic.Add((New-FOMsiTweak -Devices $msiDevices -SetHighPriority))
    } else {
        Write-Host '  MSI mode already enabled everywhere it can be.' -ForegroundColor DarkGray
    }

    if ($usbDevices.Count -gt 0) {
        Write-Host ''
        Write-Host "  USB power management can be disabled on $($usbDevices.Count) device(s):" -ForegroundColor Cyan
        foreach ($d in $usbDevices) {
            $tag = if ($d.LooksLikeController) { '  <-- controller' } else { '' }
            Write-Host "    - $($d.FriendlyName)$tag" -ForegroundColor DarkGray
        }
        $null = $synthetic.Add((New-FOUsbPowerTweak -Devices $usbDevices))
    } else {
        Write-Host '  USB power management already disabled everywhere relevant.' -ForegroundColor DarkGray
    }

    if ($synthetic.Count -eq 0) { return }

    if (-not (Confirm-FOAction -Message 'Apply these device-level changes?' `
        -Consequence 'These require a restart. They are journaled and revertible like every other tweak.')) {
        Write-Host '  Cancelled.' -ForegroundColor Yellow
        return
    }

    Export-FORegistryBackup -Label 'before-device-tweaks' | Out-Null
    $result = Invoke-FOApply -Tweaks $synthetic.ToArray() -Description 'Device latency tweaks'
    Write-Host ''
    Write-FOResultTable -Result $result
    Write-Host ''
    Write-Host '  RESTART REQUIRED for interrupt changes to take effect.' -ForegroundColor Yellow
}

function Invoke-FOFortniteSetup {
    Write-Host ''
    Write-Host (Get-FOFortniteReport)
    Write-Host ''
    Write-Host '  CALIBRATION' -ForegroundColor Cyan
    Write-Host '  For an accurate frame cap I need your real in-match FPS, not Creative.' -ForegroundColor DarkGray
    Write-Host '  Play a match with the FPS counter on, note your average and your worst' -ForegroundColor DarkGray
    Write-Host '  sustained value during a fight, then enter them. Leave blank to skip.' -ForegroundColor DarkGray
    Write-Host ''

    $avgInput = (Read-Host '  Average in-match FPS (blank to skip)').Trim()
    $lowInput = (Read-Host '  Worst sustained FPS during a fight (blank to skip)').Trim()

    $avg = 0; $low = 0
    [void][int]::TryParse($avgInput, [ref]$avg)
    [void][int]::TryParse($lowInput, [ref]$low)

    $recommendation = Get-FORecommendedFrameCap -ObservedAverageFps $avg -ObservedLowFps $low

    Write-Host ''
    Write-Host "  Recommended frame cap: $($recommendation.RecommendedCap) FPS" -ForegroundColor Green
    Write-Host "  Basis: $($recommendation.Basis)" -ForegroundColor DarkGray
    Write-Host ''
    foreach ($reason in $recommendation.Reasoning) {
        foreach ($line in (Split-FOText -Text $reason -Width 68)) {
            Write-Host "  $line" -ForegroundColor DarkGray
        }
        Write-Host ''
    }

    $capInput = (Read-Host "  Frame cap to write [$($recommendation.RecommendedCap)]").Trim()
    $cap = $recommendation.RecommendedCap
    if ($capInput) { [void][int]::TryParse($capInput, [ref]$cap) }

    if (-not (Confirm-FOAction -Message "Write competitive settings with a $cap FPS cap?" `
        -Consequence 'Your current GameUserSettings.ini is backed up first and can be restored from the menu. Fortnite must be fully closed.')) {
        Write-Host '  Cancelled.' -ForegroundColor Yellow
        return
    }

    try {
        $result = Set-FOFortniteSettings -FrameCap $cap
        Write-Host ''
        Write-Host "  Settings written. Backup: $($result.Backup)" -ForegroundColor Green
        Write-Host ''
        Write-Host '  STILL TO DO BY HAND (these are not in the config file):' -ForegroundColor Yellow
        foreach ($step in @(
            'In Fortnite: set Rendering Mode to Performance, and NVIDIA Reflex to On + Boost.',
            "In NVIDIA Control Panel, for Fortnite: Max Frame Rate = $cap, Low Latency Mode = Ultra, Power Management = Prefer Maximum Performance, Vertical Sync = Off.",
            'Confirm your monitor is running at its full refresh rate in Windows display settings.'
        )) {
            foreach ($line in (Split-FOText -Text "- $step" -Width 68)) {
                Write-Host "  $line" -ForegroundColor DarkGray
            }
        }
    } catch {
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-FORevertMenu {
    $applied = Get-FOAppliedTweaks
    if ($applied.Count -eq 0) {
        Write-Host '  Nothing has been applied. Nothing to revert.' -ForegroundColor DarkGray
        return
    }

    Write-Host ''
    Write-Host "  $($applied.Count) tweak(s) currently applied:" -ForegroundColor Cyan
    $index = 1
    $ordered = @($applied.Keys | Sort-Object)
    foreach ($id in $ordered) {
        Write-Host ('    {0,3}. {1}' -f $index, $id) -ForegroundColor DarkGray
        $index++
    }

    Write-Host ''
    Write-Host '  Enter numbers to revert (e.g. 1,3,5), ALL for everything, or blank to cancel.'
    $selection = (Read-Host '  Selection').Trim()

    if (-not $selection) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }

    if ($selection -ieq 'all') {
        if (-not (Confirm-FOAction -Message "Revert ALL $($applied.Count) tweak(s)?" `
            -Consequence 'Every captured prior value is restored. A restart is recommended afterwards.')) {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return
        }
        $result = Invoke-FORevert -All
    } else {
        $chosen = foreach ($part in ($selection -split ',')) {
            $n = 0
            if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $ordered.Count) {
                $ordered[$n - 1]
            }
        }
        $chosen = @($chosen)
        if ($chosen.Count -eq 0) { Write-Host '  Nothing valid selected.' -ForegroundColor Yellow; return }
        $result = Invoke-FORevert -TweakId $chosen
    }

    Write-Host ''
    Write-FOResultTable -Result $result
    Write-Host ''
    Write-Host "  Reverted: $($result.Reverted)" -ForegroundColor Green
    Write-Host '  Restart to be sure everything is back to its prior state.' -ForegroundColor Yellow
}

function Show-FOStatus {
    Write-Host ''
    Write-Host '  TWEAK STATUS (read from the live system, not the journal)' -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 68)) -ForegroundColor DarkGray

    $tweaks = Get-FOTweaks -MaxTier 'nuclear' -IncludeInapplicable
    foreach ($tweak in $tweaks) {
        if (-not $tweak.applicable) {
            Write-Host ('  {0,-13} {1,-44}' -f 'N/A', $tweak.id) -ForegroundColor DarkGray
            continue
        }

        $status = Get-FOTweakStatus -Tweak $tweak
        $colour = switch ($status.Status) {
            'Applied'    { 'Green' }
            'Partial'    { 'Yellow' }
            'NotApplied' { 'DarkGray' }
            default      { 'DarkGray' }
        }

        # Drift detection: journal says applied, system disagrees. This is how
        # you catch Windows Update or Tamper Protection undoing your work.
        $drift = ''
        if ($status.Journaled -and $status.Status -ne 'Applied') {
            $drift = '  <-- DRIFTED (journal says applied, system disagrees)'
            $colour = 'Red'
        }

        Write-Host ('  {0,-13} {1,-44} {2}/{3}{4}' -f $status.Status, $tweak.id, $status.Matched, $status.Total, $drift) -ForegroundColor $colour
    }
}

function Invoke-FODebloatMenu {
    Write-Host ''
    Write-Host (Get-FODebloatReport)
    Write-Host ''

    $assessment = Get-FOBloatAssessment
    $bloat = @($assessment | Where-Object { $_.Verdict -eq 'Bloat' -and $_.Type -eq 'Appx' })
    $startup = @(Get-FOStartupInventory | Where-Object { $_.RegistryPath })

    Write-Host '  ACTIONS' -ForegroundColor Cyan
    Write-Host "    1. Remove $($bloat.Count) Store app(s) classified as bloat"
    Write-Host "    2. Disable startup entries ($($startup.Count) found)"
    Write-Host '    3. Back to main menu'

    $choice = Read-FOChoice -Prompt '  Choice' -Valid @('1', '2', '3')

    switch ($choice) {
        '1' {
            if ($bloat.Count -eq 0) { Write-Host '  Nothing classified as bloat.' -ForegroundColor DarkGray; return }
            Write-Host ''
            foreach ($item in $bloat) { Write-Host "    - $($item.Name)" -ForegroundColor DarkGray }
            if (-not (Confirm-FOAction -Message "Remove $($bloat.Count) Store app(s)?" `
                -Consequence 'This is NOT journal-revertible. A removal manifest with reinstall commands for each package is written to ProgramData\FortressOne\removals first. Most can also be reinstalled from the Store.')) {
                Write-Host '  Cancelled.' -ForegroundColor Yellow
                return
            }
            $results = Remove-FOAppxPackage -Packages $bloat -AllUsers
            foreach ($r in $results) {
                $colour = if ($r.Outcome -eq 'Removed') { 'Green' } elseif ($r.Outcome -eq 'Vetoed') { 'Yellow' } else { 'Red' }
                Write-Host ('  {0,-12} {1}' -f $r.Outcome, $r.Name) -ForegroundColor $colour
            }
        }
        '2' {
            if ($startup.Count -eq 0) { Write-Host '  No registry startup entries found.' -ForegroundColor DarkGray; return }
            Write-Host ''
            $i = 1
            foreach ($item in $startup) {
                Write-Host ('    {0,3}. {1,-30} {2}' -f $i, $item.Name, $item.Scope) -ForegroundColor DarkGray
                $i++
            }
            Write-Host ''
            $selection = (Read-Host '  Numbers to remove (e.g. 1,3), or blank to cancel').Trim()
            if (-not $selection) { return }

            $chosen = foreach ($part in ($selection -split ',')) {
                $n = 0
                if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $startup.Count) { $startup[$n - 1] }
            }
            $chosen = @($chosen)
            if ($chosen.Count -eq 0) { return }

            $tweak = New-FOStartupDisableTweak -StartupItems $chosen
            $result = Invoke-FOApply -Tweaks @($tweak) -Description 'Remove startup entries'
            Write-FOResultTable -Result $result
        }
    }
}

# ---------------------------------------------------------------------------
# Non-interactive entry points
# ---------------------------------------------------------------------------

switch ($PSCmdlet.ParameterSetName) {
    'Diagnose' {
        Write-FOBanner
        Invoke-FODiagnostics | Out-Null
        exit 0
    }
    'Apply' {
        Write-FOBanner
        Invoke-FOApplyTier -Tier $Apply -Categories $Category -DryRun:$DryRun | Out-Null
        exit 0
    }
    'Revert' {
        Write-FOBanner
        if ($All) {
            $result = Invoke-FORevert -All -DryRun:$DryRun
        } elseif ($TweakId) {
            $result = Invoke-FORevert -TweakId $TweakId -DryRun:$DryRun
        } else {
            Write-Host '  Specify -All or -TweakId.' -ForegroundColor Yellow
            exit 1
        }
        Write-FOResultTable -Result $result
        exit 0
    }
    'Status' {
        Write-FOBanner
        Show-FOStatus
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------

while ($true) {
    Write-FOBanner

    Write-Host '   1.  Run full diagnostics          (changes nothing - START HERE)' -ForegroundColor White
    Write-Host '   2.  Fortnite settings and frame cap  (the actual input-delay fix)' -ForegroundColor Green
    Write-Host '   3.  Preview tweaks (dry run)      (see exactly what would change)' -ForegroundColor White
    Write-Host '   4.  Apply CORE tweaks             (low risk, high value)' -ForegroundColor White
    Write-Host '   5.  Apply AGGRESSIVE tweaks       (real trade-offs, read first)' -ForegroundColor Yellow
    Write-Host '   6.  Apply NUCLEAR tweaks          (security costs - read first)' -ForegroundColor Red
    Write-Host '   7.  Device latency (MSI mode, USB power)' -ForegroundColor White
    Write-Host '   8.  Debloat: apps and startup' -ForegroundColor White
    Write-Host '   9.  Show current status / detect drift' -ForegroundColor White
    Write-Host '  10.  REVERT tweaks' -ForegroundColor Cyan
    Write-Host '  11.  Restore Fortnite config from backup' -ForegroundColor Cyan
    Write-Host '  12.  Network test only (ping, bufferbloat, regions)' -ForegroundColor White
    Write-Host '   0.  Exit' -ForegroundColor DarkGray

    $choice = Read-FOChoice -Prompt '  Choice' -Valid @('0','1','2','3','4','5','6','7','8','9','10','11','12')

    switch ($choice) {
        '1'  { Invoke-FODiagnostics | Out-Null }
        '2'  { Invoke-FOFortniteSetup }
        '3'  {
            $tier = Read-FOChoice -Prompt '  Tier to preview (core/aggressive/nuclear)' -Valid @('core','aggressive','nuclear')
            Invoke-FOApplyTier -Tier $tier -DryRun | Out-Null
        }
        '4'  { Invoke-FOApplyTier -Tier 'core' | Out-Null }
        '5'  { Invoke-FOApplyTier -Tier 'aggressive' | Out-Null }
        '6'  { Invoke-FOApplyTier -Tier 'nuclear' | Out-Null }
        '7'  { Invoke-FODeviceTweaks }
        '8'  { Invoke-FODebloatMenu }
        '9'  { Show-FOStatus }
        '10' { Invoke-FORevertMenu }
        '11' {
            try {
                Restore-FOFortniteConfig
                Write-Host '  Fortnite config restored from the most recent backup.' -ForegroundColor Green
            } catch {
                Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        '12' { Write-Host (Get-FONetworkReport) }
        '0'  {
            Write-Host ''
            Write-Host "  Log: $(Get-FOLogPath)" -ForegroundColor DarkGray
            Write-Host '  Everything applied can be undone with:  .\FortressOne.ps1 -Revert -All' -ForegroundColor DarkGray
            Write-Host ''
            exit 0
        }
    }

    Write-Host ''
    Read-Host '  Press Enter to return to the menu' | Out-Null
}
