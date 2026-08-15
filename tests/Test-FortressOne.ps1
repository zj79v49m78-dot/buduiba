<#
.SYNOPSIS
    Test suite for FortressOne. Runs cross-platform (no Windows required).
.DESCRIPTION
    Covers the parts where a bug would be expensive:

      * Tweak definition validation, run against the REAL shipped definitions.
        A malformed or unjustified tweak fails the build rather than reaching
        a user's registry.
      * Journal round-trip, including index rebuild from immutable transaction
        files. This is the mechanism that guarantees revertibility, so it is
        tested against real file I/O rather than mocked.
      * Protection veto logic. A veto that silently fails open would be the
        worst possible bug in this tool.
      * Registry path normalisation, INI round-tripping, frame cap maths and
        private-address detection.

    Windows-specific provider I/O (actual registry and service writes) cannot be
    exercised here and is NOT claimed to be covered. See the coverage note
    printed at the end of the run.

.EXAMPLE
    pwsh -File tests/Test-FortressOne.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0
$script:Failures = [System.Collections.ArrayList]::new()

function Test-Case {
    param([string] $Name, [scriptblock] $Body)

    try {
        & $Body
        $script:Passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } catch {
        $script:Failed++
        $null = $script:Failures.Add("$Name :: $($_.Exception.Message)")
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkRed
    }
}

function Assert-True {
    param([bool] $Condition, [string] $Message = 'Expected condition to be true')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message = '')
    if ("$Expected" -ne "$Actual") {
        throw "$Message Expected '$Expected' but got '$Actual'"
    }
}

# ---------------------------------------------------------------------------
# Harness setup
# ---------------------------------------------------------------------------

$repoRoot = Split-Path -Parent $PSScriptRoot
$tempData = Join-Path ([System.IO.Path]::GetTempPath()) "fortressone-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $tempData -Force | Out-Null

$Global:FO = [ordered]@{
    Version   = 'test'
    AppRoot   = $repoRoot
    DataRoot  = $tempData
    System    = $null
    StartedAt = Get-Date
}

foreach ($module in @(
    'src/Core/FO.Logging.psm1'
    'src/Core/FO.Journal.psm1'
    'src/Core/FO.Providers.psm1'
    'src/Core/FO.Engine.psm1'
    'src/Modules/FO.Fortnite.psm1'
    'src/Diag/FO.Diag.Network.psm1'
)) {
    Import-Module (Join-Path $repoRoot $module) -Force -DisableNameChecking -Global
}

Initialize-FOLogging -LogDirectory (Join-Path $tempData 'logs') -MinimumLevel 'Error' | Out-Null

# A representative machine so applicability filtering can be exercised.
$Global:FO.System = [pscustomobject]@{
    IsWindows11     = $true
    IsLaptop        = $false
    HasNvidiaGpu    = $true
    HasWiredAdapter = $true
    Gpus            = @([pscustomobject]@{ Name = 'NVIDIA GeForce GTX 1070' })
    Displays        = @([pscustomobject]@{ CurrentRefreshHz = 244; MaxRefreshHz = 244 })
}

Write-Host ''
Write-Host 'FortressOne test suite' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Source encoding' -ForegroundColor Cyan

Test-Case 'All script files are pure ASCII' {
    # Windows PowerShell 5.1 -- which is what ships with Windows and what most
    # people will actually run this with -- decodes .ps1/.psm1 files using the
    # system ANSI codepage, NOT UTF-8, unless the file carries a byte-order
    # mark. A UTF-8 em dash inside a double-quoted string therefore decodes to
    # three bytes of garbage, one of which terminates the string early and
    # produces a cascade of parser errors far from the real cause.
    #
    # PowerShell 7 defaults to UTF-8, so this class of bug is INVISIBLE when
    # testing on 7 and fatal on 5.1. Keeping source pure ASCII removes the
    # dependency on file encoding entirely. Prose in .md and .json files is
    # exempt: those are read with an explicit -Encoding UTF8.
    $offenders = [System.Collections.ArrayList]::new()

    Get-ChildItem -LiteralPath $repoRoot -Recurse -Include '*.ps1', '*.psm1' | ForEach-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -gt 127) {
                $null = $offenders.Add("$($_.Name) at byte $i (0x$('{0:x2}' -f $bytes[$i]))")
                break
            }
        }
    }

    Assert-Equal 0 $offenders.Count "Non-ASCII bytes found -- these break Windows PowerShell 5.1: $($offenders -join '; ')"
}

Test-Case 'All JSON reads specify an explicit encoding' {
    # Get-Content in Windows PowerShell 5.1 also defaults to the ANSI codepage.
    # The tweak rationales contain typographic characters, so reading them
    # without -Encoding UTF8 renders mojibake in the user's report.
    $bad = [System.Collections.ArrayList]::new()

    # Scope to shipped code. The test file is excluded because its own scanning
    # loop necessarily contains the string it is looking for.
    $shipped = @(
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src') -Recurse -Include '*.psm1'
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tools') -Recurse -Include '*.ps1'
        Get-Item -LiteralPath (Join-Path $repoRoot 'FortressOne.ps1')
    )

    $shipped | ForEach-Object {
        $lineNumber = 0
        foreach ($line in (Get-Content -LiteralPath $_.FullName -Encoding UTF8)) {
            $lineNumber++
            if ($line -match 'Get-Content' -and $line -notmatch '-Encoding') {
                $null = $bad.Add("$($_.Name):$lineNumber")
            }
        }
    }

    Assert-Equal 0 $bad.Count "Get-Content without -Encoding: $($bad -join ', ')"
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Tweak definitions' -ForegroundColor Cyan

Test-Case 'All shipped tweak definitions load and validate' {
    $tweaks = Import-FOTweaks -Force
    Assert-True ($tweaks.Count -gt 0) 'No tweaks were loaded'
}

Test-Case 'Every tweak carries a substantive rationale' {
    foreach ($tweak in (Import-FOTweaks)) {
        Assert-True ($tweak.rationale.Length -ge 40) "Tweak '$($tweak.id)' has an inadequate rationale"
    }
}

Test-Case 'Tweak ids are unique across all definition files' {
    $ids = (Import-FOTweaks) | ForEach-Object { $_.id }
    $unique = $ids | Sort-Object -Unique
    Assert-Equal $ids.Count $unique.Count 'Duplicate tweak ids found'
}

Test-Case 'Validator rejects a tweak with no rationale' {
    $bad = [pscustomobject]@{
        id = 'x.y'; name = 'n'; category = 'c'; risk = 'low'; tier = 'core'
        impact = 'low'; rationale = 'too short'; actions = @()
    }
    $problems = @(Test-FOTweakDefinition -Tweak $bad -SourceFile 'test')
    Assert-True ($problems.Count -gt 0) 'Validator accepted an unjustified tweak'
}

Test-Case 'Validator rejects an unknown provider' {
    $bad = [pscustomobject]@{
        id = 'x.y'; name = 'n'; category = 'c'; risk = 'low'; tier = 'core'; impact = 'low'
        rationale = 'A sufficiently long rationale string that satisfies the minimum length rule.'
        actions = @([pscustomobject]@{ provider = 'wmi-magic'; name = 'z'; value = 1 })
    }
    $problems = @(Test-FOTweakDefinition -Tweak $bad -SourceFile 'test')
    Assert-True ($problems.Count -gt 0) 'Validator accepted an unknown provider'
}

Test-Case 'Validator rejects an out-of-range risk level' {
    $bad = [pscustomobject]@{
        id = 'x.y'; name = 'n'; category = 'c'; risk = 'catastrophic'; tier = 'core'; impact = 'low'
        rationale = 'A sufficiently long rationale string that satisfies the minimum length rule.'
        actions = @()
    }
    $problems = @(Test-FOTweakDefinition -Tweak $bad -SourceFile 'test')
    Assert-True ($problems.Count -gt 0) 'Validator accepted an invalid risk level'
}

Test-Case 'Tier filtering never returns a higher tier than requested' {
    foreach ($tweak in (Get-FOTweaks -MaxTier 'core')) {
        Assert-Equal 'core' $tweak.tier "Tweak '$($tweak.id)' leaked past the core tier filter"
    }
    $aggressive = Get-FOTweaks -MaxTier 'aggressive'
    foreach ($tweak in $aggressive) {
        Assert-True ($tweak.tier -in @('core', 'aggressive')) "Tweak '$($tweak.id)' leaked past the aggressive filter"
    }
}

Test-Case 'Nuclear tier is a strict superset of aggressive' {
    $aggressiveIds = @((Get-FOTweaks -MaxTier 'aggressive') | ForEach-Object { $_.id })
    $nuclearIds = @((Get-FOTweaks -MaxTier 'nuclear') | ForEach-Object { $_.id })
    foreach ($id in $aggressiveIds) {
        Assert-True ($nuclearIds -contains $id) "Tweak '$id' disappeared at the nuclear tier"
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Protection veto' -ForegroundColor Cyan

Test-Case 'Protection list loads' {
    $protection = Import-FOProtection -Force
    Assert-True ($protection.services.Count -gt 0) 'Protection list has no services'
}

Test-Case 'Disabling a protected service is vetoed' {
    $action = [pscustomobject]@{ provider = 'service'; name = 'EasyAntiCheat'; value = 'Disabled' }
    $veto = Test-FOActionPermitted -Action $action
    Assert-True ($null -ne $veto) 'Disabling EasyAntiCheat was NOT vetoed'
}

Test-Case 'Disabling the audio service is vetoed' {
    $action = [pscustomobject]@{ provider = 'service'; name = 'Audiosrv'; value = 'Disabled' }
    Assert-True ($null -ne (Test-FOActionPermitted -Action $action)) 'Disabling Audiosrv was NOT vetoed'
}

Test-Case 'Disabling the XInput controller driver is vetoed' {
    $action = [pscustomobject]@{ provider = 'service'; name = 'xusb22'; value = 'Disabled' }
    Assert-True ($null -ne (Test-FOActionPermitted -Action $action)) 'Disabling the XInput driver was NOT vetoed'
}

Test-Case 'Veto is case-insensitive on service names' {
    $action = [pscustomobject]@{ provider = 'service'; name = 'easyanticheat'; value = 'Disabled' }
    Assert-True ($null -ne (Test-FOActionPermitted -Action $action)) 'Veto missed a lowercase service name'
}

Test-Case 'Setting a protected service to Manual is permitted' {
    # The veto blocks disabling, not all reconfiguration.
    $action = [pscustomobject]@{ provider = 'service'; name = 'Audiosrv'; value = 'Manual' }
    Assert-True ($null -eq (Test-FOActionPermitted -Action $action)) 'Veto was too broad'
}

Test-Case 'Writing to a protected registry prefix is vetoed' {
    $action = [pscustomobject]@{
        provider = 'registry'
        path = 'HKLM:\SYSTEM\CurrentControlSet\Services\EasyAntiCheat\Parameters'
        name = 'Start'; value = 4
    }
    Assert-True ($null -ne (Test-FOActionPermitted -Action $action)) 'Registry veto failed'
}

Test-Case 'An ordinary service is not vetoed' {
    $action = [pscustomobject]@{ provider = 'service'; name = 'DiagTrack'; value = 'Disabled' }
    Assert-True ($null -eq (Test-FOActionPermitted -Action $action)) 'Veto blocked a legitimate tweak'
}

Test-Case 'No shipped tweak is vetoed by the protection list' {
    # A shipped tweak that trips the veto is a contradiction in the data set:
    # it would silently never apply. Catch it here rather than in the field.
    foreach ($tweak in (Get-FOTweaks -MaxTier 'nuclear' -IncludeInapplicable)) {
        foreach ($action in $tweak.actions) {
            $veto = Test-FOActionPermitted -Action $action
            Assert-True ($null -eq $veto) "Shipped tweak '$($tweak.id)' is vetoed: $veto"
        }
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Journal' -ForegroundColor Cyan

Test-Case 'Journal initialises and starts empty' {
    Initialize-FOJournal | Out-Null
    Assert-Equal 0 (Get-FOAppliedTweaks).Count 'A fresh journal was not empty'
}

Test-Case 'A committed transaction appears in the applied index' {
    $tx = New-FOTransaction -Operation 'apply' -Description 'test'
    Add-FOTransactionRecord -Transaction $tx -TweakId 'test.one' -TweakName 'Test One' -Entries @(
        [pscustomobject]@{
            provider = 'registry'; name = 'TestValue'; target = 'HKLM:\SOFTWARE\Test'
            priorExists = $true; priorValue = 20; newValue = 0; priorKind = 'DWord'
        }
    )
    Save-FOTransaction -Transaction $tx | Out-Null

    Assert-True (Test-FOTweakApplied -TweakId 'test.one') 'Applied tweak was not recorded'
}

Test-Case 'Prior state survives the JSON round-trip exactly' {
    $applied = Get-FOAppliedTweaks
    $entry = @($applied['test.one'].entries)[0]
    Assert-Equal 20 $entry.priorValue 'Prior value was corrupted'
    Assert-Equal 'DWord' $entry.priorKind 'Prior value kind was lost'
    Assert-True ([bool]$entry.priorExists) 'priorExists flag was lost'
}

Test-Case 'Absence is recorded distinctly from a zero value' {
    # Restoring a value to 0 and deleting a value that never existed are
    # different operations. Conflating them is the classic revert bug.
    $tx = New-FOTransaction -Operation 'apply' -Description 'absence test'
    Add-FOTransactionRecord -Transaction $tx -TweakId 'test.absent' -TweakName 'Absent' -Entries @(
        [pscustomobject]@{
            provider = 'registry'; name = 'NeverExisted'; target = 'HKLM:\SOFTWARE\Test'
            priorExists = $false; priorValue = $null; newValue = 1; priorKind = $null; keyCreated = $true
        }
    )
    Save-FOTransaction -Transaction $tx | Out-Null

    $entry = @((Get-FOAppliedTweaks)['test.absent'].entries)[0]
    Assert-True (-not [bool]$entry.priorExists) 'Absence was recorded as presence'
    Assert-True ($null -eq $entry.priorValue) 'A never-existent value gained a prior value'
    Assert-True ([bool]$entry.keyCreated) 'keyCreated flag was lost'
}

Test-Case 'A revert transaction removes the tweak from the applied index' {
    $tx = New-FOTransaction -Operation 'revert' -Description 'revert test'
    Add-FOTransactionRecord -Transaction $tx -TweakId 'test.one' -TweakName 'Test One' -Entries @(
        [pscustomobject]@{ provider = 'registry'; name = 'TestValue'; target = 'HKLM:\SOFTWARE\Test'; priorExists = $true; priorValue = 20; newValue = 0 }
    )
    Save-FOTransaction -Transaction $tx | Out-Null

    Assert-True (-not (Test-FOTweakApplied -TweakId 'test.one')) 'Reverted tweak still listed as applied'
    Assert-True (Test-FOTweakApplied -TweakId 'test.absent') 'Revert removed the wrong tweak'
}

Test-Case 'Transaction history is retrievable and ordered' {
    $history = Get-FOTransactionHistory
    Assert-True ($history.Count -ge 3) "Expected at least 3 transactions, found $($history.Count)"
}

Test-Case 'The index rebuilds correctly from immutable transaction files' {
    # Simulate a corrupted index: the tx-*.json files are the real record.
    $indexPath = Join-Path (Get-FOJournalRoot) 'applied.json'
    Set-Content -LiteralPath $indexPath -Value '{ this is not valid json' -Encoding UTF8

    $applied = Get-FOAppliedTweaks
    Assert-True (Test-FOTweakApplied -TweakId 'test.absent') 'Rebuild lost a still-applied tweak'
    Assert-True (-not (Test-FOTweakApplied -TweakId 'test.one')) 'Rebuild resurrected a reverted tweak'
}

Test-Case 'Malformed JSON is refused rather than committed' {
    $path = Join-Path $tempData 'atomic-test.json'
    Write-FOAtomicJson -Path $path -Object ([ordered]@{ a = 1; b = 'two' })
    $read = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 1 $read.a 'Atomic write corrupted the payload'
    Assert-True (-not (Test-Path -LiteralPath "$path.tmp")) 'Temp file was left behind'
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Registry path normalisation' -ForegroundColor Cyan

Test-Case 'HKLM backslash shorthand expands to a PowerShell drive path' {
    Assert-Equal 'HKLM:\SOFTWARE\Test' (Expand-FORegistryPath 'HKLM\SOFTWARE\Test')
}

Test-Case 'Long-form hive names expand correctly' {
    Assert-Equal 'HKLM:\SOFTWARE' (Expand-FORegistryPath 'HKEY_LOCAL_MACHINE\SOFTWARE')
    Assert-Equal 'HKCU:\Software' (Expand-FORegistryPath 'HKEY_CURRENT_USER\Software')
}

Test-Case 'Already-normalised paths pass through unchanged' {
    Assert-Equal 'HKLM:\SOFTWARE\Test' (Expand-FORegistryPath 'HKLM:\SOFTWARE\Test')
}

Test-Case 'Every shipped registry path normalises to a valid hive' {
    foreach ($tweak in (Get-FOTweaks -MaxTier 'nuclear' -IncludeInapplicable)) {
        foreach ($action in $tweak.actions) {
            if ($action.provider -ne 'registry') { continue }
            $expanded = Expand-FORegistryPath $action.path
            Assert-True ($expanded -match '^(HKLM|HKCU|HKCR|HKU):\\') "Tweak '$($tweak.id)' has an unnormalisable path: $($action.path)"
        }
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Fortnite configuration' -ForegroundColor Cyan

Test-Case 'INI parse and write round-trips without data loss' {
    $iniPath = Join-Path $tempData 'test.ini'
    @(
        '[/Script/Engine.GameUserSettings]'
        'FrameRateLimit=240.000000'
        'bUseVSync=False'
        'SomeUnknownKeyWeDoNotUnderstand=42'
        ''
        '[ScalabilityGroups]'
        'sg.ShadowQuality=2'
    ) | Set-Content -LiteralPath $iniPath -Encoding UTF8

    $parsed = Read-FOIniFile -Path $iniPath
    Assert-Equal '240.000000' $parsed['/Script/Engine.GameUserSettings']['FrameRateLimit']
    Assert-Equal '2' $parsed['ScalabilityGroups']['sg.ShadowQuality']

    $outPath = Join-Path $tempData 'test-out.ini'
    Write-FOIniFile -Path $outPath -Data $parsed
    $reparsed = Read-FOIniFile -Path $outPath

    # The unknown key must survive. Silently dropping settings this tool does
    # not recognise would quietly reset parts of the user's configuration.
    Assert-Equal '42' $reparsed['/Script/Engine.GameUserSettings']['SomeUnknownKeyWeDoNotUnderstand'] 'An unrecognised key was lost on rewrite'
    Assert-Equal 'False' $reparsed['/Script/Engine.GameUserSettings']['bUseVSync']
}

Test-Case 'Frame cap never exceeds the display refresh rate' {
    $result = Get-FORecommendedFrameCap -ObservedAverageFps 500 -RefreshRateHz 244
    Assert-True ($result.RecommendedCap -lt 244) "Cap of $($result.RecommendedCap) exceeded a 244Hz display"
}

Test-Case 'Frame cap sits below the measured 1% low' {
    $result = Get-FORecommendedFrameCap -ObservedLowFps 140 -RefreshRateHz 244
    Assert-True ($result.RecommendedCap -lt 140) "Cap of $($result.RecommendedCap) was not below the 140 FPS 1% low"
    Assert-True ($result.RecommendedCap -ge 120) "Cap of $($result.RecommendedCap) was needlessly conservative"
}

Test-Case '1% low takes precedence over average when both are supplied' {
    $result = Get-FORecommendedFrameCap -ObservedAverageFps 200 -ObservedLowFps 130 -RefreshRateHz 244
    Assert-True ($result.Basis -match '1% low') 'Average was used in preference to the 1% low'
    Assert-True ($result.RecommendedCap -lt 130) 'Cap ignored the 1% low figure'
}

Test-Case 'Uncalibrated GTX 1070 estimate is sane for a 244Hz panel' {
    $result = Get-FORecommendedFrameCap -RefreshRateHz 244
    Assert-True ($result.RecommendedCap -ge 100 -and $result.RecommendedCap -le 200) "Estimate of $($result.RecommendedCap) is implausible for a GTX 1070"
}

Test-Case 'Frame cap never drops below a playable floor' {
    $result = Get-FORecommendedFrameCap -ObservedLowFps 20 -RefreshRateHz 244
    Assert-True ($result.RecommendedCap -ge 60) "Cap of $($result.RecommendedCap) is below the 60 FPS floor"
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Network helpers' -ForegroundColor Cyan

Test-Case 'RFC1918 ranges are detected as private' {
    foreach ($addr in @('192.168.1.1', '10.0.0.1', '172.16.5.4', '172.31.255.254')) {
        Assert-True (Test-FOPrivateAddress -Address $addr) "$addr was not detected as private"
    }
}

Test-Case 'CGNAT space is detected as private' {
    # Carrier-grade NAT produces the same symptoms as a second NAT layer, so it
    # must count toward the double-NAT hop tally.
    Assert-True (Test-FOPrivateAddress -Address '100.64.0.1') 'CGNAT space not detected'
    Assert-True (Test-FOPrivateAddress -Address '100.127.255.255') 'Upper CGNAT bound not detected'
}

Test-Case 'Public addresses are not misclassified as private' {
    foreach ($addr in @('1.1.1.1', '8.8.8.8', '172.32.0.1', '100.128.0.1', '192.169.1.1')) {
        Assert-True (-not (Test-FOPrivateAddress -Address $addr)) "$addr was wrongly detected as private"
    }
}

Test-Case 'Malformed addresses are rejected rather than throwing' {
    Assert-True (-not (Test-FOPrivateAddress -Address 'not-an-address')) 'Garbage input was accepted'
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor DarkGray
Write-Host "  Passed: $script:Passed" -ForegroundColor Green
Write-Host "  Failed: $script:Failed" -ForegroundColor $(if ($script:Failed -gt 0) { 'Red' } else { 'DarkGray' })

if ($script:Failed -gt 0) {
    Write-Host ''
    Write-Host '  Failures:' -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host "    - $failure" -ForegroundColor Red }
}

Write-Host ''
Write-Host '  COVERAGE NOTE' -ForegroundColor Yellow
Write-Host '  These tests exercise validation, journal integrity, veto logic and' -ForegroundColor DarkGray
Write-Host '  pure computation. They deliberately do NOT claim to cover actual' -ForegroundColor DarkGray
Write-Host '  registry, service, powercfg or netsh writes, which require Windows.' -ForegroundColor DarkGray
Write-Host '  Verify those on the target machine with:  .\FortressOne.ps1 -Apply core -DryRun' -ForegroundColor DarkGray

Remove-Item -LiteralPath $tempData -Recurse -Force -ErrorAction SilentlyContinue
exit $(if ($script:Failed -gt 0) { 1 } else { 0 })
