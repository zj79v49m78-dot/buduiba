<#
.SYNOPSIS
    FortressOne state providers -- read/write adapters for each kind of Windows state.
.DESCRIPTION
    Every provider implements the same three-verb contract:

        Get-FOTargetState  -> @{ Exists = <bool>; Value = <object>; Meta = @{} }
        Set-FOTargetState  -> applies a value
        Reset-FOTargetState -> restores a captured prior state (including absence)

    Because the engine only ever talks to this contract, adding a new class of
    tweak means adding one provider here -- the journal, revert, dry-run, and
    verification logic all work on it for free.

    IMPORTANT DESIGN RULE: providers never decide policy. They do not know which
    values are "good". They only know how to read and write. All judgement lives
    in the tweak definitions under data/tweaks/. This keeps the risky code (that
    writes to your system) small, uniform, and auditable.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

function Get-FORegistryState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name
    )

    $result = @{ Exists = $false; Value = $null; Meta = @{ keyExists = $false; valueKind = $null } }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }
    $result.Meta.keyExists = $true

    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        $names = $key.GetValueNames()

        # Default value is represented as an empty name by the .NET API.
        $lookup = if ($Name -eq '(Default)') { '' } else { $Name }

        if ($names -notcontains $lookup) {
            return $result
        }

        $result.Exists = $true
        $result.Value = $key.GetValue($lookup, $null, 'DoNotExpandEnvironmentNames')
        $result.Meta.valueKind = [string]$key.GetValueKind($lookup)

        # Binary and MultiString values must be serialised for JSON round-trip.
        if ($result.Meta.valueKind -eq 'Binary' -and $null -ne $result.Value) {
            $result.Value = ($result.Value | ForEach-Object { $_.ToString('x2') }) -join ''
        }
    } catch {
        Write-FOLog -Level Warn -Message 'Registry read failed' -Data @{ path = $Path; name = $Name; error = $_.Exception.Message }
    }

    return $result
}

function Set-FORegistryState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [AllowNull()] $Value,
        [ValidateSet('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary')]
        [string] $Type = 'DWord'
    )

    # A null value means "this value should not exist".
    if ($null -eq $Value) {
        if (Test-Path -LiteralPath $Path) {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
        }
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }

    $converted = switch ($Type) {
        'DWord'       { [int]$Value }
        'QWord'       { [int64]$Value }
        'Binary'      { ConvertFrom-FOHexString -Hex ([string]$Value) }
        'MultiString' { [string[]]$Value }
        default       { [string]$Value }
    }

    New-ItemProperty -LiteralPath $Path -Name $Name -Value $converted `
        -PropertyType $Type -Force -ErrorAction Stop | Out-Null
}

function ConvertFrom-FOHexString {
    param([string] $Hex)
    if ([string]::IsNullOrWhiteSpace($Hex)) { return , @() }
    $bytes = for ($i = 0; $i -lt $Hex.Length; $i += 2) {
        [Convert]::ToByte($Hex.Substring($i, 2), 16)
    }
    return , ([byte[]]$bytes)
}

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------

# Numeric start types as stored in the registry. Set-Service is unreliable for
# protected services, so the registry is the source of truth in both directions.
$script:ServiceStartMap = @{
    'Boot' = 0; 'System' = 1; 'Automatic' = 2; 'Manual' = 3; 'Disabled' = 4
}
$script:ServiceStartReverse = @{
    0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled'
}

function Get-FOServiceState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name)

    $result = @{ Exists = $false; Value = $null; Meta = @{ status = $null; displayName = $null } }
    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"

    if (-not (Test-Path -LiteralPath $path)) { return $result }

    try {
        $start = (Get-ItemProperty -LiteralPath $path -Name 'Start' -ErrorAction Stop).Start
        $result.Exists = $true
        $result.Value = $script:ServiceStartReverse[[int]$start]

        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($svc) {
            $result.Meta.status = [string]$svc.Status
            $result.Meta.displayName = $svc.DisplayName
        }
    } catch {
        Write-FOLog -Level Warn -Message 'Service read failed' -Data @{ service = $Name; error = $_.Exception.Message }
    }

    return $result
}

function Set-FOServiceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)]
        [ValidateSet('Boot', 'System', 'Automatic', 'Manual', 'Disabled')]
        [string] $StartupType,
        [switch] $StopNow
    )

    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-FOLog -Level Debug -Message 'Service not present; skipping' -Data @{ service = $Name }
        return
    }

    if ($StopNow -and $StartupType -eq 'Disabled') {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            try {
                Stop-Service -Name $Name -Force -NoWait -ErrorAction Stop
            } catch {
                Write-FOLog -Level Debug -Message 'Service would not stop (will apply on reboot)' -Data @{ service = $Name }
            }
        }
    }

    Set-ItemProperty -LiteralPath $path -Name 'Start' `
        -Value $script:ServiceStartMap[$StartupType] -Type DWord -Force -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Scheduled tasks
# ---------------------------------------------------------------------------

function Get-FOScheduledTaskState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TaskPath,
        [Parameter(Mandatory)] [string] $TaskName
    )

    $result = @{ Exists = $false; Value = $null; Meta = @{} }
    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        $result.Exists = $true
        $result.Value = [string]$task.State   # Ready | Disabled | Running
    } catch {
        # Task genuinely absent on this SKU -- not an error worth surfacing.
    }
    return $result
}

function Set-FOScheduledTaskState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TaskPath,
        [Parameter(Mandatory)] [string] $TaskName,
        [Parameter(Mandatory)] [ValidateSet('Ready', 'Disabled')] [string] $State
    )

    try {
        if ($State -eq 'Disabled') {
            Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        } else {
            Enable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-FOLog -Level Warn -Message 'Scheduled task change failed' -Data @{
            task = "$TaskPath$TaskName"; error = $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# Power settings (powercfg)
# ---------------------------------------------------------------------------

function Get-FOPowerSettingState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SubgroupGuid,
        [Parameter(Mandatory)] [string] $SettingGuid,
        [ValidateSet('AC', 'DC')] [string] $PowerSource = 'AC'
    )

    $result = @{ Exists = $false; Value = $null; Meta = @{ scheme = $null } }

    try {
        $active = (powercfg /getactivescheme) 2>$null
        if ($active -match 'GUID:\s*([0-9a-fA-F-]{36})') {
            $scheme = $Matches[1]
        } else {
            return $result
        }
        $result.Meta.scheme = $scheme

        $query = (powercfg /query $scheme $SubgroupGuid $SettingGuid) 2>$null
        if (-not $query) { return $result }

        $pattern = if ($PowerSource -eq 'AC') {
            'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)'
        } else {
            'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)'
        }

        $joined = $query -join "`n"
        if ($joined -match $pattern) {
            $result.Exists = $true
            $result.Value = [int]('0x' + $Matches[1])
        }
    } catch {
        Write-FOLog -Level Warn -Message 'Power setting read failed' -Data @{
            setting = $SettingGuid; error = $_.Exception.Message
        }
    }

    return $result
}

function Set-FOPowerSettingState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SubgroupGuid,
        [Parameter(Mandatory)] [string] $SettingGuid,
        [Parameter(Mandatory)] [int]    $Value,
        [ValidateSet('AC', 'DC')] [string] $PowerSource = 'AC'
    )

    $active = (powercfg /getactivescheme) 2>$null
    if ($active -notmatch 'GUID:\s*([0-9a-fA-F-]{36})') {
        throw 'Could not determine the active power scheme.'
    }
    $scheme = $Matches[1]

    $verb = if ($PowerSource -eq 'AC') { '/setacvalueindex' } else { '/setdcvalueindex' }
    $null = powercfg $verb $scheme $SubgroupGuid $SettingGuid $Value 2>&1
    $null = powercfg /setactive $scheme 2>&1
}

# ---------------------------------------------------------------------------
# TCP global parameters (netsh int tcp)
# ---------------------------------------------------------------------------

function Get-FOTcpGlobalState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Parameter)

    $result = @{ Exists = $false; Value = $null; Meta = @{} }

    # Get-NetTCPSetting is the supported API and is far more reliable to parse
    # than netsh output, which is localised.
    try {
        $setting = Get-NetTCPSetting -SettingName 'Internet' -ErrorAction Stop
        if ((Test-FOHasProperty -InputObject $setting -Name $Parameter)) {
            $result.Exists = $true
            $result.Value = [string]$setting.$Parameter
            return $result
        }
    } catch { }

    try {
        $global = Get-NetTCPSetting -ErrorAction Stop | Select-Object -First 1
        if ($global -and (Test-FOHasProperty -InputObject $global -Name $Parameter)) {
            $result.Exists = $true
            $result.Value = [string]$global.$Parameter
        }
    } catch {
        Write-FOLog -Level Warn -Message 'TCP setting read failed' -Data @{ parameter = $Parameter }
    }

    return $result
}

function Set-FOTcpGlobalState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Parameter,
        [Parameter(Mandatory)] [string] $Value
    )

    try {
        $splat = @{ SettingName = 'Internet'; ErrorAction = 'Stop' }
        $splat[$Parameter] = $Value
        Set-NetTCPSetting @splat
    } catch {
        Write-FOLog -Level Warn -Message 'TCP setting write failed' -Data @{
            parameter = $Parameter; value = $Value; error = $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# Network adapter advanced properties
# ---------------------------------------------------------------------------

function Get-FONetAdapterState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Keyword,
        [string] $AdapterName
    )

    $result = @{ Exists = $false; Value = $null; Meta = @{ adapter = $null } }

    $adapter = Get-FOPrimaryAdapter -AdapterName $AdapterName
    if (-not $adapter) { return $result }
    $result.Meta.adapter = $adapter.Name

    try {
        $prop = Get-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword $Keyword -ErrorAction Stop
        $result.Exists = $true
        $result.Value = [string]$prop.RegistryValue[0]
    } catch {
        # Not every NIC exposes every keyword; absence is normal.
    }

    return $result
}

function Set-FONetAdapterState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Keyword,
        [Parameter(Mandatory)] [string] $Value,
        [string] $AdapterName
    )

    $adapter = Get-FOPrimaryAdapter -AdapterName $AdapterName
    if (-not $adapter) { return }

    try {
        Set-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword $Keyword `
            -RegistryValue $Value -NoRestart -ErrorAction Stop
    } catch {
        Write-FOLog -Level Warn -Message 'NIC property write failed' -Data @{
            keyword = $Keyword; error = $_.Exception.Message
        }
    }
}

function Get-FOPrimaryAdapter {
    <#
    .SYNOPSIS
        Returns the wired adapter actually carrying traffic -- the one that
        matters for game latency, not a virtual or disconnected one.
    #>
    [CmdletBinding()]
    param([string] $AdapterName)

    if ($AdapterName) {
        return (Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue)
    }

    $candidates = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' }

    if (-not $candidates) { return $null }

    # Prefer the adapter holding the default route.
    $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric | Select-Object -First 1

    if ($defaultRoute) {
        $match = $candidates | Where-Object { $_.ifIndex -eq $defaultRoute.ifIndex }
        if ($match) { return $match }
    }

    return ($candidates | Sort-Object -Property LinkSpeed -Descending | Select-Object -First 1)
}

# ---------------------------------------------------------------------------
# Boot configuration (bcdedit)
# ---------------------------------------------------------------------------

function Get-FOBcdState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Element)

    $result = @{ Exists = $false; Value = $null; Meta = @{} }

    try {
        $output = (bcdedit /enum '{current}') 2>$null
        if (-not $output) { return $result }

        foreach ($line in $output) {
            if ($line -match "^\s*$([regex]::Escape($Element))\s+(.+?)\s*$") {
                $result.Exists = $true
                $result.Value = $Matches[1].Trim()
                break
            }
        }
    } catch {
        Write-FOLog -Level Warn -Message 'bcdedit read failed' -Data @{ element = $Element }
    }

    return $result
}

function Set-FOBcdState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Element,
        [Parameter(Mandatory)] [AllowNull()] [string] $Value
    )

    if ($null -eq $Value -or $Value -eq '') {
        $null = bcdedit /deletevalue $Element 2>&1
    } else {
        $null = bcdedit /set $Element $Value 2>&1
    }
}

# ---------------------------------------------------------------------------
# Microsoft Defender exclusions
# ---------------------------------------------------------------------------

function Get-FODefenderExclusionState {
    <#
    .SYNOPSIS
        Reports whether a path is currently excluded from Defender scanning.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $result = @{ Exists = $false; Value = $null; Meta = @{} }

    try {
        $prefs = Get-MpPreference -ErrorAction Stop
        $existing = @($prefs.ExclusionPath)
        if ($existing -and ($existing | Where-Object { $_ -ieq $Path })) {
            $result.Exists = $true
            $result.Value = 'excluded'
        }
    } catch {
        Write-FOLog -Level Warn -Message 'Could not read Defender exclusions' -Data @{ error = $_.Exception.Message }
    }

    return $result
}

function Set-FODefenderExclusionState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowNull()] $Value
    )

    try {
        if ($null -eq $Value) {
            Remove-MpPreference -ExclusionPath $Path -ErrorAction Stop
        } else {
            Add-MpPreference -ExclusionPath $Path -ErrorAction Stop
        }
    } catch {
        Write-FOLog -Level Warn -Message 'Defender exclusion change failed' -Data @{
            path = $Path; error = $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# Unified dispatch
# ---------------------------------------------------------------------------

function Get-FOTargetState {
    <#
    .SYNOPSIS
        Reads current state for any action definition.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action)

    switch ($Action.provider) {
        'registry' {
            return (Get-FORegistryState -Path (Expand-FORegistryPath $Action.path) -Name $Action.name)
        }
        'service' {
            return (Get-FOServiceState -Name $Action.name)
        }
        'scheduledtask' {
            return (Get-FOScheduledTaskState -TaskPath $Action.taskPath -TaskName $Action.name)
        }
        'power' {
            $src = if ((Test-FOHasProperty -InputObject $Action -Name 'powerSource')) { $Action.powerSource } else { 'AC' }
            return (Get-FOPowerSettingState -SubgroupGuid $Action.subgroup -SettingGuid $Action.setting -PowerSource $src)
        }
        'tcp' {
            return (Get-FOTcpGlobalState -Parameter $Action.name)
        }
        'netadapter' {
            return (Get-FONetAdapterState -Keyword $Action.name)
        }
        'bcd' {
            return (Get-FOBcdState -Element $Action.name)
        }
        'defenderexclusion' {
            return (Get-FODefenderExclusionState -Path $Action.name)
        }
        default {
            throw "Unknown provider '$($Action.provider)'"
        }
    }
}

function Set-FOTargetState {
    <#
    .SYNOPSIS
        Applies the desired value described by an action definition.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action)

    switch ($Action.provider) {
        'registry' {
            $type = if ((Test-FOHasProperty -InputObject $Action -Name 'type')) { $Action.type } else { 'DWord' }
            Set-FORegistryState -Path (Expand-FORegistryPath $Action.path) -Name $Action.name -Value $Action.value -Type $type
        }
        'service' {
            $stop = ((Test-FOHasProperty -InputObject $Action -Name 'stopNow')) -and $Action.stopNow
            Set-FOServiceState -Name $Action.name -StartupType ([string]$Action.value) -StopNow:$stop
        }
        'scheduledtask' {
            Set-FOScheduledTaskState -TaskPath $Action.taskPath -TaskName $Action.name -State ([string]$Action.value)
        }
        'power' {
            $src = if ((Test-FOHasProperty -InputObject $Action -Name 'powerSource')) { $Action.powerSource } else { 'AC' }
            Set-FOPowerSettingState -SubgroupGuid $Action.subgroup -SettingGuid $Action.setting -Value ([int]$Action.value) -PowerSource $src
        }
        'tcp' {
            Set-FOTcpGlobalState -Parameter $Action.name -Value ([string]$Action.value)
        }
        'netadapter' {
            Set-FONetAdapterState -Keyword $Action.name -Value ([string]$Action.value)
        }
        'bcd' {
            Set-FOBcdState -Element $Action.name -Value ([string]$Action.value)
        }
        'defenderexclusion' {
            Set-FODefenderExclusionState -Path $Action.name -Value $Action.value
        }
        default {
            throw "Unknown provider '$($Action.provider)'"
        }
    }
}

function Reset-FOTargetState {
    <#
    .SYNOPSIS
        Restores one journal entry's captured prior state.
    .DESCRIPTION
        This is the entire revert mechanism. It deliberately distinguishes
        "restore the old value" from "remove the value because it did not exist
        before" -- see the note in FO.Journal.psm1 for why that matters.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry)

    $priorExists = [bool]$Entry.priorExists
    $priorValue  = $Entry.priorValue

    switch ($Entry.provider) {
        'registry' {
            $path = Expand-FORegistryPath $Entry.target
            if ($priorExists) {
                $kind = if ((Test-FOHasProperty -InputObject $Entry -Name 'priorKind') -and $Entry.priorKind) { $Entry.priorKind } else { 'DWord' }
                Set-FORegistryState -Path $path -Name $Entry.name -Value $priorValue -Type $kind
            } else {
                if (Test-Path -LiteralPath $path) {
                    Remove-ItemProperty -LiteralPath $path -Name $Entry.name -Force -ErrorAction SilentlyContinue
                }
                # If FortressOne created the key itself and it is now empty, take it away too.
                if (((Test-FOHasProperty -InputObject $Entry -Name 'keyCreated')) -and $Entry.keyCreated -and (Test-Path -LiteralPath $path)) {
                    $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
                    if ($key -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) {
                        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
        'service' {
            if ($priorExists) { Set-FOServiceState -Name $Entry.name -StartupType ([string]$priorValue) }
        }
        'scheduledtask' {
            if ($priorExists) {
                # 'Running' is a transient state, not a configuration; the
                # meaningful restore target is 'Ready'.
                $state = if ([string]$priorValue -eq 'Disabled') { 'Disabled' } else { 'Ready' }
                Set-FOScheduledTaskState -TaskPath $Entry.taskPath -TaskName $Entry.name -State $state
            }
        }
        'power' {
            if ($priorExists) {
                $src = if ((Test-FOHasProperty -InputObject $Entry -Name 'powerSource') -and $Entry.powerSource) { $Entry.powerSource } else { 'AC' }
                Set-FOPowerSettingState -SubgroupGuid $Entry.subgroup -SettingGuid $Entry.setting -Value ([int]$priorValue) -PowerSource $src
            }
        }
        'tcp' {
            if ($priorExists) { Set-FOTcpGlobalState -Parameter $Entry.name -Value ([string]$priorValue) }
        }
        'netadapter' {
            if ($priorExists) { Set-FONetAdapterState -Keyword $Entry.name -Value ([string]$priorValue) }
        }
        'bcd' {
            if ($priorExists) {
                Set-FOBcdState -Element $Entry.name -Value ([string]$priorValue)
            } else {
                Set-FOBcdState -Element $Entry.name -Value $null
            }
        }
        'defenderexclusion' {
            # If the exclusion existed before we ran, leave it. If it did not,
            # remove the one we added -- do not strip exclusions the user set up
            # themselves for some other program.
            if (-not $priorExists) {
                Set-FODefenderExclusionState -Path $Entry.name -Value $null
            }
        }
        default {
            Write-FOLog -Level Error -Message 'Cannot revert unknown provider' -Data @{ provider = $Entry.provider }
        }
    }
}

function Expand-FORegistryPath {
    <#
    .SYNOPSIS
        Normalises registry path shorthand used in tweak definitions.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    $p = $Path -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' `
               -replace '^HKEY_CURRENT_USER', 'HKCU:' `
               -replace '^HKEY_CLASSES_ROOT', 'HKCR:' `
               -replace '^HKEY_USERS', 'HKU:'

    if ($p -match '^HKLM\\') { $p = $p -replace '^HKLM\\', 'HKLM:\' }
    if ($p -match '^HKCU\\') { $p = $p -replace '^HKCU\\', 'HKCU:\' }

    return $p
}

Export-ModuleMember -Function `
    Get-FOTargetState, Set-FOTargetState, Reset-FOTargetState, `
    Get-FORegistryState, Set-FORegistryState, `
    Get-FOServiceState, Set-FOServiceState, `
    Get-FOScheduledTaskState, Set-FOScheduledTaskState, `
    Get-FOPowerSettingState, Set-FOPowerSettingState, `
    Get-FOTcpGlobalState, Set-FOTcpGlobalState, `
    Get-FONetAdapterState, Set-FONetAdapterState, Get-FOPrimaryAdapter, `
    Get-FOBcdState, Set-FOBcdState, Expand-FORegistryPath, `
    Get-FODefenderExclusionState, Set-FODefenderExclusionState
