<#
.SYNOPSIS
    Fortnite configuration, frame-cap calibration and Defender exclusions.
.DESCRIPTION
    This module contains the single most important change in the entire tool:
    the frame rate cap.

    WHAT IS ACTUALLY WRONG (the render queue)
    -----------------------------------------
    When the GPU cannot keep up with the frames the CPU is submitting, the
    frames do not simply arrive slower — they QUEUE. The CPU runs ahead,
    submitting work the GPU has not started yet. By the time a frame reaches
    the display it may have been sitting in that queue for several frame
    intervals, and crucially, the controller input that produced it was sampled
    at the START of that wait.

    That is why the symptom is so specific and so confusing:

      Creative, simple map : GPU at ~60%, queue empty,  input feels instant
      Real match           : GPU at ~100%, queue full,  input feels terrible

    Same PC. Same settings. Same controller. The only variable is GPU headroom.

    THE FIX (counterintuitive but well established)
    -----------------------------------------------
    Cap the frame rate BELOW what the GPU can sustain in its worst case. The
    GPU then always finishes a frame before the next is submitted, the queue
    stays empty, and input latency collapses to roughly one frame interval.

    You will see a SMALLER number on the FPS counter and the game will feel
    dramatically better. If you find that hard to accept, cap it, play three
    matches, then uncap it and play three more. The difference is not subtle.

    A NOTE ON WHAT THIS MODULE WILL NOT DO
    --------------------------------------
    It writes legitimate video settings to GameUserSettings.ini — the same
    values you could set through the game's own options menu. It does NOT write
    Engine.ini rendering overrides that strip foliage, disable fog, or otherwise
    alter what you can see relative to other players. Those are config exploits.
    Epic has actively removed them, players have been penalised for them in
    competitive contexts, and they are cheating regardless of how they are
    marketed. Everything here is a setting you are entitled to change.
#>

Set-StrictMode -Version Latest

function Get-FOFortnitePaths {
    <#
    .SYNOPSIS
        Locates the Fortnite installation and configuration directories.
    #>
    [CmdletBinding()]
    param()

    $result = [ordered]@{
        ConfigDir     = $null
        GameUserSettings = $null
        InstallDir    = $null
        LauncherDir   = $null
        Found         = $false
    }

    $configDir = Join-Path $env:LOCALAPPDATA 'FortniteGame\Saved\Config\WindowsClient'
    if (Test-Path -LiteralPath $configDir) {
        $result.ConfigDir = $configDir
        $gus = Join-Path $configDir 'GameUserSettings.ini'
        if (Test-Path -LiteralPath $gus) {
            $result.GameUserSettings = $gus
            $result.Found = $true
        }
    }

    # Locate the install via the Epic launcher manifests, which is far more
    # reliable than guessing at Program Files paths.
    $manifestDir = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (Test-Path -LiteralPath $manifestDir) {
        foreach ($file in (Get-ChildItem -LiteralPath $manifestDir -Filter '*.item' -ErrorAction SilentlyContinue)) {
            try {
                $manifest = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                if ($manifest.DisplayName -match 'Fortnite' -or $manifest.MandatoryAppFolderName -eq 'FortniteGame') {
                    $result.InstallDir = $manifest.InstallLocation
                    break
                }
            } catch { }
        }
    }

    foreach ($candidate in @(
        (Join-Path ${env:ProgramFiles(x86)} 'Epic Games\Launcher'),
        (Join-Path $env:ProgramFiles 'Epic Games\Launcher')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $result.LauncherDir = $candidate
            break
        }
    }

    return [pscustomobject]$result
}

# ---------------------------------------------------------------------------
# INI handling
# ---------------------------------------------------------------------------

function Read-FOIniFile {
    <#
    .SYNOPSIS
        Parses an INI file into an ordered section/key structure.
    .DESCRIPTION
        Preserves section order and unknown keys so that writing the file back
        does not discard settings this tool does not understand. Fortnite writes
        a great many keys here; silently dropping the ones we do not recognise
        would be destructive.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $result = [ordered]@{}
    $section = '_root'
    $result[$section] = [ordered]@{}

    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $trimmed = $line.Trim()

        if ($trimmed -match '^\[(.+)\]$') {
            $section = $Matches[1]
            if (-not $result.Contains($section)) { $result[$section] = [ordered]@{} }
            continue
        }

        if ($trimmed -eq '' -or $trimmed.StartsWith(';')) { continue }

        $idx = $trimmed.IndexOf('=')
        if ($idx -lt 1) { continue }

        $key = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()
        $result[$section][$key] = $value
    }

    return $result
}

function Write-FOIniFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Data
    )

    $output = [System.Collections.ArrayList]::new()

    foreach ($sectionName in $Data.Keys) {
        if ($sectionName -ne '_root') {
            $null = $output.Add("[$sectionName]")
        }
        foreach ($key in $Data[$sectionName].Keys) {
            $null = $output.Add("$key=$($Data[$sectionName][$key])")
        }
        $null = $output.Add('')
    }

    Set-Content -LiteralPath $Path -Value ($output -join [Environment]::NewLine) -Encoding UTF8 -Force
}

function Backup-FOFortniteConfig {
    <#
    .SYNOPSIS
        Copies the current config into the FortressOne backup directory.
    #>
    [CmdletBinding()]
    param()

    $paths = Get-FOFortnitePaths
    if (-not $paths.Found) {
        Write-FOLog -Level Warn -Message 'Fortnite config not found; nothing to back up'
        return $null
    }

    $backupDir = Join-Path $Global:FO.DataRoot 'backups\fortnite'
    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dest = Join-Path $backupDir "GameUserSettings-$stamp.ini"
    Copy-Item -LiteralPath $paths.GameUserSettings -Destination $dest -Force

    Write-FOLog -Level Info -Message 'Fortnite config backed up' -Data @{ path = $dest }
    return $dest
}

function Restore-FOFortniteConfig {
    <#
    .SYNOPSIS
        Restores the most recent (or a named) config backup.
    #>
    [CmdletBinding()]
    param([string] $BackupPath)

    $paths = Get-FOFortnitePaths
    if (-not $paths.ConfigDir) { throw 'Fortnite config directory not found.' }

    if (-not $BackupPath) {
        $backupDir = Join-Path $Global:FO.DataRoot 'backups\fortnite'
        $latest = Get-ChildItem -LiteralPath $backupDir -Filter 'GameUserSettings-*.ini' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { throw 'No Fortnite config backup found.' }
        $BackupPath = $latest.FullName
    }

    $target = Join-Path $paths.ConfigDir 'GameUserSettings.ini'
    Copy-Item -LiteralPath $BackupPath -Destination $target -Force
    Write-FOLog -Level Info -Message 'Fortnite config restored' -Data @{ from = $BackupPath }
}

# ---------------------------------------------------------------------------
# Frame cap calculation
# ---------------------------------------------------------------------------

function Get-FORecommendedFrameCap {
    <#
    .SYNOPSIS
        Calculates the frame cap that minimises input latency.
    .PARAMETER ObservedAverageFps
        Your actual average FPS in a real match (NOT in Creative). If you supply
        this, the recommendation is calibrated to your hardware rather than
        estimated. Getting this number is worth the five minutes it takes.
    .PARAMETER ObservedLowFps
        Your 1% low FPS in a real match, if you know it. This is the better
        input, because the queue fills during the WORST moments, not the average
        ones — and the worst moments are exactly when you need input fidelity.
    #>
    [CmdletBinding()]
    param(
        [int] $ObservedAverageFps,
        [int] $ObservedLowFps,
        [int] $RefreshRateHz
    )

    if (-not $RefreshRateHz) {
        $RefreshRateHz = ($Global:FO.System.Displays | Measure-Object -Property CurrentRefreshHz -Maximum).Maximum
    }
    if (-not $RefreshRateHz -or $RefreshRateHz -le 0) { $RefreshRateHz = 240 }

    $reasoning = [System.Collections.ArrayList]::new()

    # The ceiling: never cap above the display. Frames the panel cannot show are
    # latency with extra steps.
    $refreshCeiling = $RefreshRateHz - 3
    $null = $reasoning.Add("Display runs at $RefreshRateHz Hz, so the absolute ceiling is $refreshCeiling FPS. Rendering above your refresh rate does not reduce latency meaningfully once Reflex is on, and it wastes GPU headroom you need for queue drain.")

    $cap = $refreshCeiling
    $basis = 'refresh rate only (uncalibrated)'

    if ($ObservedLowFps -gt 0) {
        # Cap at ~95% of the 1% low. Below the worst case means the queue never
        # fills even in the worst moments of a match.
        $cap = [math]::Floor($ObservedLowFps * 0.95)
        $basis = "1% low FPS ($ObservedLowFps)"
        $null = $reasoning.Add("Calibrated against your 1% low of $ObservedLowFps FPS. Capping at 95 percent of that ($cap) means the GPU keeps headroom even during your worst frames — which is exactly when the render queue would otherwise fill and your input would feel worst.")
    }
    elseif ($ObservedAverageFps -gt 0) {
        # Without a 1% low figure, 85% of average is a reasonable proxy, since
        # 1% lows typically sit somewhere around 80-90% of average.
        $cap = [math]::Floor($ObservedAverageFps * 0.85)
        $basis = "average FPS ($ObservedAverageFps)"
        $null = $reasoning.Add("Calibrated against your average of $ObservedAverageFps FPS. 85 percent of average ($cap) approximates your 1% low, since lows typically land in that range. Supplying an actual 1% low figure would give a better result.")
    }
    else {
        # Uncalibrated estimate from the GPU model. Deliberately conservative.
        $gpu = ($Global:FO.System.Gpus | Select-Object -First 1)
        $estimate = switch -Regex ($gpu.Name) {
            'GTX 1050'            { 90 }
            'GTX 1060'            { 120 }
            'GTX 1070'            { 160 }
            'GTX 1080'            { 180 }
            'GTX 16'              { 150 }
            'RTX 20'              { 200 }
            'RTX 30'              { 237 }
            'RTX 40|RTX 50'       { 237 }
            default               { 144 }
        }
        $cap = [math]::Min($estimate, $refreshCeiling)
        $basis = "estimated from GPU model ($($gpu.Name))"
        $null = $reasoning.Add("No measured FPS supplied, so this is estimated from your GPU ($($gpu.Name)) in Performance Mode at 1080p. This is a STARTING POINT, not an answer — measure your actual in-match FPS and re-run this to calibrate properly.")
    }

    $cap = [math]::Min($cap, $refreshCeiling)
    $cap = [math]::Max($cap, 60)

    $null = $reasoning.Add("Final cap: $cap FPS. Set this both in Fortnite's own frame rate limit AND in the NVIDIA Control Panel's Max Frame Rate for Fortnite — belt and braces, because the two limiters behave slightly differently and having both prevents overshoot.")

    return [pscustomobject]@{
        RecommendedCap = $cap
        RefreshRateHz  = $RefreshRateHz
        Basis          = $basis
        Reasoning      = $reasoning.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Applying settings
# ---------------------------------------------------------------------------

function Set-FOFortniteSettings {
    <#
    .SYNOPSIS
        Writes competitive video settings to GameUserSettings.ini.
    .DESCRIPTION
        Backs up first, always. The game must not be running — it rewrites this
        file on exit and will overwrite anything set while it is open.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $FrameCap,
        [ValidateSet('Performance', 'DX11', 'DX12')] [string] $RenderMode = 'Performance',
        [int] $ResolutionX = 1920,
        [int] $ResolutionY = 1080,
        [switch] $WhatIf
    )

    if (Get-Process -Name 'FortniteClient-Win64-Shipping' -ErrorAction SilentlyContinue) {
        throw 'Fortnite is running. Close it completely before changing settings — the game rewrites this file on exit and would discard the changes.'
    }

    $paths = Get-FOFortnitePaths
    if (-not $paths.Found) {
        throw "GameUserSettings.ini not found. Launch Fortnite once so it creates its config, then run this again. Expected: $($paths.ConfigDir)"
    }

    $backup = Backup-FOFortniteConfig
    $ini = Read-FOIniFile -Path $paths.GameUserSettings

    $engineSection = '/Script/Engine.GameUserSettings'
    $scalability   = 'ScalabilityGroups'

    foreach ($section in @($engineSection, $scalability)) {
        if (-not $ini.Contains($section)) { $ini[$section] = [ordered]@{} }
    }

    # --- Core latency settings ---------------------------------------------
    $ini[$engineSection]['FrameRateLimit'] = ('{0:F6}' -f $FrameCap)
    $ini[$engineSection]['bUseVSync'] = 'False'
    $ini[$engineSection]['bUseDynamicResolution'] = 'False'
    $ini[$engineSection]['ResolutionSizeX'] = $ResolutionX
    $ini[$engineSection]['ResolutionSizeY'] = $ResolutionY
    $ini[$engineSection]['LastUserConfirmedResolutionSizeX'] = $ResolutionX
    $ini[$engineSection]['LastUserConfirmedResolutionSizeY'] = $ResolutionY
    # FullscreenMode 0 is true exclusive fullscreen, which gives the shortest
    # present path and lets the driver bypass the desktop compositor entirely.
    $ini[$engineSection]['FullscreenMode'] = 0
    $ini[$engineSection]['PreferredFullscreenMode'] = 0
    $ini[$engineSection]['LastConfirmedFullscreenMode'] = 0

    # --- Scalability -------------------------------------------------------
    # 100 resolution quality means no internal render-scale reduction; the other
    # groups go to their lowest setting. On a GPU-bound 1070 every one of these
    # buys back GPU headroom, and headroom is what keeps the queue empty.
    $ini[$scalability]['sg.ResolutionQuality'] = 100
    $ini[$scalability]['sg.ViewDistanceQuality'] = 2
    $ini[$scalability]['sg.AntiAliasingQuality'] = 0
    $ini[$scalability]['sg.ShadowQuality'] = 0
    $ini[$scalability]['sg.PostProcessQuality'] = 0
    $ini[$scalability]['sg.TextureQuality'] = 0
    $ini[$scalability]['sg.EffectsQuality'] = 0
    $ini[$scalability]['sg.FoliageQuality'] = 0
    $ini[$scalability]['sg.ShadingQuality'] = 0
    $ini[$scalability]['sg.ReflectionQuality'] = 0
    $ini[$scalability]['sg.GlobalIlluminationQuality'] = 0

    if ($WhatIf) {
        Write-FOLog -Level Info -Message 'WhatIf: Fortnite settings not written'
        return [pscustomobject]@{ Written = $false; Backup = $backup; FrameCap = $FrameCap }
    }

    Write-FOIniFile -Path $paths.GameUserSettings -Data $ini
    Write-FOLog -Level Info -Message 'Fortnite settings written' -Data @{ cap = $FrameCap; backup = $backup }

    return [pscustomobject]@{
        Written  = $true
        Backup   = $backup
        FrameCap = $FrameCap
        Path     = $paths.GameUserSettings
    }
}

function New-FOFortniteDefenderTweak {
    <#
    .SYNOPSIS
        Builds a synthetic tweak excluding Fortnite paths from Defender scanning.
    #>
    [CmdletBinding()]
    param()

    $paths = Get-FOFortnitePaths
    $targets = [System.Collections.ArrayList]::new()

    foreach ($candidate in @($paths.InstallDir, $paths.LauncherDir, $paths.ConfigDir)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $null = $targets.Add($candidate)
        }
    }

    if ($targets.Count -eq 0) { return $null }

    $actions = foreach ($target in $targets) {
        [pscustomobject]@{ provider = 'defenderexclusion'; name = $target; value = 'excluded' }
    }

    return [pscustomobject]@{
        id             = 'dyn.defender.fortnite-exclusions'
        name           = "Exclude Fortnite paths from Defender ($($targets.Count) path(s))"
        category       = 'nuclear'
        risk           = 'medium'
        tier           = 'aggressive'
        impact         = 'high'
        requiresReboot = $false
        rationale      = "Excludes $($targets -join '; ') from real-time scanning. Fortnite streams thousands of asset reads per match and each one otherwise passes through the Defender filter driver. This captures nearly all of the benefit of disabling Defender while leaving the rest of the machine protected — it is the better trade by a wide margin."
        actions        = @($actions)
        applicable     = $true
        inapplicableReason = $null
        sourceFile     = '<dynamic>'
    }
}

function Get-FOFortniteReport {
    <#
    .SYNOPSIS
        Reports current Fortnite config and what should change.
    #>
    [CmdletBinding()]
    param([int] $ObservedAverageFps, [int] $ObservedLowFps)

    $lines = [System.Collections.ArrayList]::new()
    $null = $lines.Add('FORTNITE CONFIGURATION')
    $null = $lines.Add('=' * 72)

    $paths = Get-FOFortnitePaths
    if (-not $paths.Found) {
        $null = $lines.Add('  GameUserSettings.ini not found.')
        $null = $lines.Add('  Launch Fortnite once to generate it, then re-run this report.')
        return ($lines -join [Environment]::NewLine)
    }

    $ini = Read-FOIniFile -Path $paths.GameUserSettings
    $engineSection = '/Script/Engine.GameUserSettings'

    $currentCap = if ($ini.Contains($engineSection) -and $ini[$engineSection].Contains('FrameRateLimit')) {
        [math]::Round([double]$ini[$engineSection]['FrameRateLimit'])
    } else { 0 }

    $currentMode = if ($ini.Contains($engineSection) -and $ini[$engineSection].Contains('FullscreenMode')) {
        switch ([int]$ini[$engineSection]['FullscreenMode']) {
            0 { 'Fullscreen (exclusive)' }
            1 { 'Windowed Fullscreen' }
            2 { 'Windowed' }
            default { 'Unknown' }
        }
    } else { 'Unknown' }

    $null = $lines.Add("  Config      : $($paths.GameUserSettings)")
    if ($paths.InstallDir) { $null = $lines.Add("  Install     : $($paths.InstallDir)") }
    $null = $lines.Add("  Frame cap   : $(if ($currentCap -gt 0) { "$currentCap FPS" } else { 'UNCAPPED' })")
    $null = $lines.Add("  Window mode : $currentMode")
    $null = $lines.Add('')

    $recommendation = Get-FORecommendedFrameCap -ObservedAverageFps $ObservedAverageFps -ObservedLowFps $ObservedLowFps

    $null = $lines.Add('FRAME CAP ANALYSIS')
    $null = $lines.Add('-' * 72)
    $null = $lines.Add("  Recommended cap : $($recommendation.RecommendedCap) FPS")
    $null = $lines.Add("  Basis           : $($recommendation.Basis)")
    $null = $lines.Add('')
    foreach ($reason in $recommendation.Reasoning) {
        foreach ($wrapped in (Split-FOText -Width 68 -Text $reason)) {
            $null = $lines.Add("  $wrapped")
        }
        $null = $lines.Add('')
    }

    if ($currentCap -eq 0) {
        $null = $lines.Add('  [CRITICAL] Your frame rate is UNCAPPED.')
        foreach ($wrapped in (Split-FOText -Width 66 -Text 'On a GPU-bound system this is the primary cause of input delay. The CPU submits frames as fast as it can, they queue behind the GPU, and every queued frame adds latency between your thumb moving and the screen responding. This is the change to make first.')) {
            $null = $lines.Add("        $wrapped")
        }
    } elseif ($currentCap -gt $recommendation.RecommendedCap + 15) {
        $null = $lines.Add("  [WARN] Your cap of $currentCap is above the recommended $($recommendation.RecommendedCap).")
        foreach ($wrapped in (Split-FOText -Width 66 -Text 'A cap set above what the GPU can actually sustain is no cap at all during the moments that matter. Lower it.')) {
            $null = $lines.Add("        $wrapped")
        }
    }

    if ($currentMode -ne 'Fullscreen (exclusive)') {
        $null = $lines.Add('')
        $null = $lines.Add("  [WARN] Window mode is '$currentMode', not exclusive fullscreen.")
        foreach ($wrapped in (Split-FOText -Width 66 -Text 'Exclusive fullscreen gives the shortest present path and lets the driver bypass the desktop compositor. Windowed and borderless both route through DWM, adding up to a frame of latency.')) {
            $null = $lines.Add("        $wrapped")
        }
    }

    return ($lines -join [Environment]::NewLine)
}

Export-ModuleMember -Function `
    Get-FOFortnitePaths, Read-FOIniFile, Write-FOIniFile, `
    Backup-FOFortniteConfig, Restore-FOFortniteConfig, `
    Get-FORecommendedFrameCap, Set-FOFortniteSettings, `
    New-FOFortniteDefenderTweak, Get-FOFortniteReport
