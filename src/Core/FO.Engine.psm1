<#
.SYNOPSIS
    FortressOne tweak engine -- loads, validates, applies, verifies and reverts tweaks.
.DESCRIPTION
    The engine is deliberately the only component permitted to mutate system
    state, and it always does so in the same order:

        1. Resolve the tweak's actions.
        2. Check every action against the protection list (hard veto).
        3. READ the current state of every target.
        4. Record that state in the journal transaction.
        5. WRITE the new state.
        6. Commit the transaction to disk.

    Step 3 always precedes step 5, and step 4 always precedes step 5. That
    ordering is what guarantees there is no such thing as a change FortressOne
    made but cannot undo.
#>

Set-StrictMode -Version Latest

$script:TweakCache = $null
$script:Protection = $null

# ---------------------------------------------------------------------------
# Loading and validation
# ---------------------------------------------------------------------------

function Import-FOTweaks {
    <#
    .SYNOPSIS
        Loads and validates every tweak definition from data/tweaks/.
    #>
    [CmdletBinding()]
    param([switch] $Force)

    if ($script:TweakCache -and -not $Force) { return $script:TweakCache }

    $dir = Join-Path $Global:FO.AppRoot 'data\tweaks'
    if (-not (Test-Path -LiteralPath $dir)) {
        throw "Tweak definition directory missing: $dir"
    }

    $all = [System.Collections.ArrayList]::new()
    $seenIds = @{}

    foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.json' | Sort-Object Name)) {
        try {
            $doc = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw "Tweak file '$($file.Name)' is not valid JSON: $($_.Exception.Message)"
        }

        foreach ($tweak in $doc.tweaks) {
            # @() is required: an ArrayList returned empty is unwrapped to $null
            # by PowerShell, and .Count on $null throws under StrictMode.
            $problems = @(Test-FOTweakDefinition -Tweak $tweak -SourceFile $file.Name)
            if ($problems.Count -gt 0) {
                foreach ($p in $problems) {
                    Write-FOLog -Level Error -Message "Invalid tweak definition: $p"
                }
                throw "Tweak validation failed in '$($file.Name)'. Refusing to run with a malformed definition set."
            }

            if ($seenIds.ContainsKey($tweak.id)) {
                throw "Duplicate tweak id '$($tweak.id)' (in $($file.Name) and $($seenIds[$tweak.id]))"
            }
            $seenIds[$tweak.id] = $file.Name

            Add-Member -InputObject $tweak -NotePropertyName 'sourceFile' -NotePropertyValue $file.Name -Force
            $null = $all.Add($tweak)
        }
    }

    $script:TweakCache = $all.ToArray()
    Write-FOLog -Level Info -Message 'Tweak definitions loaded' -Data @{ count = $script:TweakCache.Count }
    return $script:TweakCache
}

function Test-FOTweakDefinition {
    <#
    .SYNOPSIS
        Structural validation. Returns an array of human-readable problems.
    #>
    [CmdletBinding()]
    param($Tweak, [string] $SourceFile)

    $problems = [System.Collections.ArrayList]::new()
    $required = @('id', 'name', 'category', 'risk', 'tier', 'impact', 'rationale', 'actions')

    foreach ($field in $required) {
        if ((-not (Test-FOHasProperty -InputObject $Tweak -Name $field))) {
            $null = $problems.Add("[$SourceFile] tweak missing required field '$field'")
        }
    }
    # Early return: without the required fields, the checks below would throw.
    # Callers wrap this in @() so an empty result is a zero-length array.
    if ($problems.Count -gt 0) { return $problems.ToArray() }

    if ($Tweak.risk -notin @('low', 'medium', 'high')) {
        $null = $problems.Add("[$SourceFile] $($Tweak.id): risk must be low|medium|high, got '$($Tweak.risk)'")
    }
    if ($Tweak.tier -notin @('core', 'aggressive', 'nuclear')) {
        $null = $problems.Add("[$SourceFile] $($Tweak.id): tier must be core|aggressive|nuclear, got '$($Tweak.tier)'")
    }
    if ($Tweak.impact -notin @('low', 'medium', 'high', 'critical')) {
        $null = $problems.Add("[$SourceFile] $($Tweak.id): impact must be low|medium|high|critical, got '$($Tweak.impact)'")
    }

    # A tweak with no stated reason is a tweak nobody can evaluate. Cargo-cult
    # tweaks are exactly what this tool exists to avoid, so an empty rationale
    # is a hard validation failure, not a style nit.
    if ([string]::IsNullOrWhiteSpace($Tweak.rationale) -or $Tweak.rationale.Length -lt 40) {
        $null = $problems.Add("[$SourceFile] $($Tweak.id): rationale must be a real explanation (>= 40 chars)")
    }

    $validProviders = @('registry', 'service', 'scheduledtask', 'power', 'tcp', 'netadapter', 'bcd', 'defenderexclusion')
    foreach ($action in $Tweak.actions) {
        if ((-not (Test-FOHasProperty -InputObject $action -Name 'provider'))) {
            $null = $problems.Add("[$SourceFile] $($Tweak.id): action missing 'provider'")
            continue
        }
        if ($action.provider -notin $validProviders) {
            $null = $problems.Add("[$SourceFile] $($Tweak.id): unknown provider '$($action.provider)'")
        }
        if ((-not (Test-FOHasProperty -InputObject $action -Name 'name'))) {
            $null = $problems.Add("[$SourceFile] $($Tweak.id): action missing 'name'")
        }
        if ($action.provider -eq 'registry' -and (-not (Test-FOHasProperty -InputObject $action -Name 'path'))) {
            $null = $problems.Add("[$SourceFile] $($Tweak.id): registry action missing 'path'")
        }
        if ($action.provider -eq 'scheduledtask' -and (-not (Test-FOHasProperty -InputObject $action -Name 'taskPath'))) {
            $null = $problems.Add("[$SourceFile] $($Tweak.id): scheduledtask action missing 'taskPath'")
        }
        if ($action.provider -eq 'power') {
            foreach ($f in @('subgroup', 'setting')) {
                if ((-not (Test-FOHasProperty -InputObject $action -Name $f))) {
                    $null = $problems.Add("[$SourceFile] $($Tweak.id): power action missing '$f'")
                }
            }
        }
    }

    return $problems.ToArray()
}

# ---------------------------------------------------------------------------
# Protection list
# ---------------------------------------------------------------------------

function Import-FOProtection {
    [CmdletBinding()]
    param([switch] $Force)

    if ($script:Protection -and -not $Force) { return $script:Protection }

    $path = Join-Path $Global:FO.AppRoot 'data\protected.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Protection list missing: $path. FortressOne will not run without it."
    }

    $script:Protection = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    return $script:Protection
}

function Test-FOActionPermitted {
    <#
    .SYNOPSIS
        Hard veto against touching anything on the protection list.
    .DESCRIPTION
        This exists because the debloat engine takes user-supplied selections.
        A user can ask FortressOne to remove almost anything -- but not the small
        set of components that Fortnite, Easy Anti-Cheat, the XInput controller
        stack, networking, or the ability to boot Windows actually depend on.

        Returns $null if permitted, or a reason string if vetoed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Action)

    $protection = Import-FOProtection

    if ($Action.provider -eq 'service') {
        foreach ($svc in $protection.services) {
            if ($Action.name -ieq $svc.name) {
                # Protected services may be reconfigured but never disabled.
                if ([string]$Action.value -eq 'Disabled') {
                    return "service '$($Action.name)' is protected: $($svc.reason)"
                }
            }
        }
    }

    if ($Action.provider -eq 'registry') {
        $path = Expand-FORegistryPath $Action.path
        foreach ($guard in $protection.registryPrefixes) {
            if ($path -like "$($guard.prefix)*") {
                return "registry path '$path' is protected: $($guard.reason)"
            }
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Applicability
# ---------------------------------------------------------------------------

function Test-FOTweakApplicable {
    <#
    .SYNOPSIS
        Decides whether a tweak is relevant to THIS machine.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Tweak)

    if ((Test-FOHasProperty -InputObject $Tweak -Name 'os') -and $Tweak.os) {
        $major = if ($Global:FO.System.IsWindows11) { '11' } else { '10' }
        if ($Tweak.os -notcontains $major) {
            return @{ Applicable = $false; Reason = "targets Windows $($Tweak.os -join '/') only" }
        }
    }

    if ((Test-FOHasProperty -InputObject $Tweak -Name 'requires') -and $Tweak.requires) {
        foreach ($req in $Tweak.requires) {
            switch ($req) {
                'nvidia' {
                    if (-not $Global:FO.System.HasNvidiaGpu) {
                        return @{ Applicable = $false; Reason = 'requires an NVIDIA GPU' }
                    }
                }
                'ethernet' {
                    if (-not $Global:FO.System.HasWiredAdapter) {
                        return @{ Applicable = $false; Reason = 'requires a wired network adapter' }
                    }
                }
                'desktop' {
                    if ($Global:FO.System.IsLaptop) {
                        return @{ Applicable = $false; Reason = 'not safe on battery-powered systems' }
                    }
                }
            }
        }
    }

    return @{ Applicable = $true; Reason = $null }
}

function Get-FOTweaks {
    <#
    .SYNOPSIS
        Returns tweaks filtered by tier, category and applicability.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('core', 'aggressive', 'nuclear')] [string] $MaxTier = 'core',
        [string[]] $Category,
        [string[]] $Id,
        [switch] $IncludeInapplicable
    )

    $tierRank = @{ 'core' = 0; 'aggressive' = 1; 'nuclear' = 2 }
    $ceiling = $tierRank[$MaxTier]

    $tweaks = Import-FOTweaks

    if ($Id) {
        $tweaks = $tweaks | Where-Object { $Id -contains $_.id }
    } else {
        $tweaks = $tweaks | Where-Object { $tierRank[$_.tier] -le $ceiling }
        if ($Category) {
            $tweaks = $tweaks | Where-Object { $Category -contains $_.category }
        }
    }

    $output = foreach ($tweak in $tweaks) {
        $applicability = Test-FOTweakApplicable -Tweak $tweak
        if (-not $applicability.Applicable -and -not $IncludeInapplicable) { continue }

        Add-Member -InputObject $tweak -NotePropertyName 'applicable' -NotePropertyValue $applicability.Applicable -Force
        Add-Member -InputObject $tweak -NotePropertyName 'inapplicableReason' -NotePropertyValue $applicability.Reason -Force
        $tweak
    }

    return @($output)
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

function Get-FOTweakStatus {
    <#
    .SYNOPSIS
        Compares a tweak's desired state against the machine's live state.
    .DESCRIPTION
        Returns Applied / NotApplied / Partial / Unknown. This is read from the
        SYSTEM, not from the journal -- so it detects drift, changes made by
        Windows Update, and changes made by other tools.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Tweak)

    $matched = 0
    $total = 0
    $details = [System.Collections.ArrayList]::new()

    foreach ($action in $Tweak.actions) {
        $total++
        try {
            $state = Get-FOTargetState -Action $action
        } catch {
            $null = $details.Add("could not read $($action.provider):$($action.name)")
            continue
        }

        $desired = $action.value
        $current = $state.Value

        $isMatch = if ($null -eq $desired) {
            -not $state.Exists
        } elseif (-not $state.Exists) {
            $false
        } else {
            [string]$current -ieq [string]$desired
        }

        if ($isMatch) { $matched++ }
        $null = $details.Add(@{
            target  = "$($action.provider):$($action.name)"
            current = if ($state.Exists) { [string]$current } else { '<absent>' }
            desired = if ($null -eq $desired) { '<absent>' } else { [string]$desired }
            match   = $isMatch
        })
    }

    $status = if ($total -eq 0) { 'Unknown' }
              elseif ($matched -eq $total) { 'Applied' }
              elseif ($matched -eq 0) { 'NotApplied' }
              else { 'Partial' }

    return [pscustomobject]@{
        TweakId  = $Tweak.id
        Status   = $status
        Matched  = $matched
        Total    = $total
        Journaled = (Test-FOTweakApplied -TweakId $Tweak.id)
        Details  = $details.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

function Invoke-FOApply {
    <#
    .SYNOPSIS
        Applies a set of tweaks inside a single reversible transaction.
    .PARAMETER DryRun
        Reads and reports everything that WOULD change without writing anything.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [array] $Tweaks,
        [switch] $DryRun,
        [string] $Description = 'Apply tweaks'
    )

    $transaction = New-FOTransaction -Operation 'apply' -Description $Description
    $results = [System.Collections.ArrayList]::new()
    $rebootNeeded = $false

    foreach ($tweak in $Tweaks) {
        $entries = [System.Collections.ArrayList]::new()
        $vetoed = $null
        $failed = $null

        # --- Veto pass: check EVERY action before writing ANY of them. -------
        # A tweak is all-or-nothing; a half-applied tweak is worse than none.
        foreach ($action in $tweak.actions) {
            $veto = Test-FOActionPermitted -Action $action
            if ($veto) { $vetoed = $veto; break }
        }

        if ($vetoed) {
            Write-FOLog -Level Warn -Message "VETOED $($tweak.id)" -Data @{ reason = $vetoed }
            $null = $results.Add([pscustomobject]@{
                TweakId = $tweak.id; Name = $tweak.name; Outcome = 'Vetoed'; Detail = $vetoed
            })
            continue
        }

        # --- Read pass: capture prior state for every target. ----------------
        foreach ($action in $tweak.actions) {
            try {
                $prior = Get-FOTargetState -Action $action
            } catch {
                $failed = "read failed for $($action.provider):$($action.name) -- $($_.Exception.Message)"
                break
            }

            $entry = [ordered]@{
                provider    = $action.provider
                name        = $action.name
                target      = if ((Test-FOHasProperty -InputObject $action -Name 'path')) { $action.path } else { $action.name }
                priorExists = $prior.Exists
                priorValue  = $prior.Value
                newValue    = $action.value
            }

            if ($action.provider -eq 'registry') {
                $entry.priorKind = $prior.Meta.valueKind
                $entry.keyCreated = -not $prior.Meta.keyExists
            }
            if ($action.provider -eq 'scheduledtask') { $entry.taskPath = $action.taskPath }
            if ($action.provider -eq 'power') {
                $entry.subgroup = $action.subgroup
                $entry.setting = $action.setting
                $entry.powerSource = if ((Test-FOHasProperty -InputObject $action -Name 'powerSource')) { $action.powerSource } else { 'AC' }
            }

            $null = $entries.Add([pscustomobject]$entry)
        }

        if ($failed) {
            Write-FOLog -Level Error -Message "SKIPPED $($tweak.id)" -Data @{ reason = $failed }
            $null = $results.Add([pscustomobject]@{
                TweakId = $tweak.id; Name = $tweak.name; Outcome = 'Failed'; Detail = $failed
            })
            continue
        }

        if ($DryRun) {
            $changes = @($entries | Where-Object {
                $cur = if ($_.priorExists) { [string]$_.priorValue } else { '<absent>' }
                $new = if ($null -eq $_.newValue) { '<absent>' } else { [string]$_.newValue }
                $cur -ine $new
            })
            $null = $results.Add([pscustomobject]@{
                TweakId = $tweak.id
                Name    = $tweak.name
                Outcome = if ($changes.Count -gt 0) { 'WouldChange' } else { 'AlreadyCorrect' }
                Detail  = "$($changes.Count) of $($entries.Count) target(s) would change"
                Entries = $entries.ToArray()
            })
            continue
        }

        # --- Journal BEFORE write. Order is the whole safety guarantee. ------
        Add-FOTransactionRecord -Transaction $transaction -TweakId $tweak.id `
            -TweakName $tweak.name -Entries $entries.ToArray()

        # --- Write pass ------------------------------------------------------
        $writeError = $null
        foreach ($action in $tweak.actions) {
            try {
                Set-FOTargetState -Action $action
            } catch {
                $writeError = "$($action.provider):$($action.name) -- $($_.Exception.Message)"
                Write-FOLog -Level Error -Message "Write failed in $($tweak.id)" -Data @{ error = $writeError }
                break
            }
        }

        if ($writeError) {
            # Roll this tweak back immediately using the state we just captured,
            # so a partial failure never leaves the machine in a mixed state.
            Write-FOLog -Level Warn -Message "Rolling back partially applied tweak $($tweak.id)"
            $captured = $entries.ToArray()
            for ($i = $captured.Count - 1; $i -ge 0; $i--) {
                try { Reset-FOTargetState -Entry $captured[$i] } catch { }
            }
            $null = $results.Add([pscustomobject]@{
                TweakId = $tweak.id; Name = $tweak.name; Outcome = 'RolledBack'; Detail = $writeError
            })
            continue
        }

        if (((Test-FOHasProperty -InputObject $tweak -Name 'requiresReboot')) -and $tweak.requiresReboot) {
            $rebootNeeded = $true
        }

        Write-FOLog -Level Info -Message "APPLIED $($tweak.id)" -Data @{ name = $tweak.name; targets = $entries.Count }
        $null = $results.Add([pscustomobject]@{
            TweakId = $tweak.id; Name = $tweak.name; Outcome = 'Applied'
            Detail = "$($entries.Count) target(s)"
        })
    }

    if (-not $DryRun) {
        $null = Save-FOTransaction -Transaction $transaction
    }

    return [pscustomobject]@{
        TransactionId = if ($DryRun) { $null } else { $transaction.transactionId }
        DryRun        = [bool]$DryRun
        Results       = $results.ToArray()
        RebootNeeded  = $rebootNeeded
        Applied       = @($results | Where-Object { $_.Outcome -eq 'Applied' }).Count
        Vetoed        = @($results | Where-Object { $_.Outcome -eq 'Vetoed' }).Count
        Failed        = @($results | Where-Object { $_.Outcome -in @('Failed', 'RolledBack') }).Count
    }
}

# ---------------------------------------------------------------------------
# Revert
# ---------------------------------------------------------------------------

function Invoke-FORevert {
    <#
    .SYNOPSIS
        Reverts tweaks by id, by transaction, or everything FortressOne ever did.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param(
        [Parameter(ParameterSetName = 'ById')]    [string[]] $TweakId,
        [Parameter(ParameterSetName = 'ByTx')]    [string]   $TransactionId,
        [Parameter(ParameterSetName = 'All')]     [switch]   $All,
        [switch] $DryRun
    )

    $applied = Get-FOAppliedTweaks
    $targets = @{}

    switch ($PSCmdlet.ParameterSetName) {
        'All' {
            $targets = $applied
        }
        'ByTx' {
            $tx = Get-FOTransaction -TransactionId $TransactionId
            foreach ($record in $tx.records) {
                if ($applied.ContainsKey($record.tweakId)) {
                    $targets[$record.tweakId] = $applied[$record.tweakId]
                }
            }
        }
        default {
            foreach ($id in $TweakId) {
                if ($applied.ContainsKey($id)) {
                    $targets[$id] = $applied[$id]
                } else {
                    Write-FOLog -Level Warn -Message "Not recorded as applied; nothing to revert" -Data @{ tweak = $id }
                }
            }
        }
    }

    if ($targets.Count -eq 0) {
        Write-FOLog -Level Info -Message 'Nothing to revert.'
        return [pscustomobject]@{ Reverted = 0; Results = @(); RebootNeeded = $false }
    }

    $transaction = New-FOTransaction -Operation 'revert' -Description "Revert $($targets.Count) tweak(s)"
    $results = [System.Collections.ArrayList]::new()

    # Revert newest-applied first so tweaks that depend on each other unwind in
    # the reverse of the order they were laid down.
    $ordered = $targets.GetEnumerator() | Sort-Object { $_.Value.appliedUtc } -Descending

    foreach ($pair in $ordered) {
        $tweakId = $pair.Key
        $record = $pair.Value
        $entries = @($record.entries)

        if ($DryRun) {
            $null = $results.Add([pscustomobject]@{
                TweakId = $tweakId; Outcome = 'WouldRevert'; Detail = "$($entries.Count) target(s)"
            })
            continue
        }

        $errors = [System.Collections.ArrayList]::new()

        # Reverse order within the tweak, mirroring how it was applied.
        for ($i = $entries.Count - 1; $i -ge 0; $i--) {
            try {
                Reset-FOTargetState -Entry $entries[$i]
            } catch {
                $null = $errors.Add("$($entries[$i].provider):$($entries[$i].name) -- $($_.Exception.Message)")
            }
        }

        if ($errors.Count -gt 0) {
            Write-FOLog -Level Error -Message "Partial revert of $tweakId" -Data @{ errors = $errors.Count }
            $null = $results.Add([pscustomobject]@{
                TweakId = $tweakId; Outcome = 'PartiallyReverted'; Detail = ($errors -join '; ')
            })
            # Deliberately NOT recorded as reverted -- it stays in the applied
            # index so the user can retry rather than silently losing the record.
            continue
        }

        Write-FOLog -Level Info -Message "REVERTED $tweakId" -Data @{ targets = $entries.Count }

        $recordName = $tweakId
        if (((Test-FOHasProperty -InputObject $record -Name 'tweakName')) -and $record.tweakName) {
            $recordName = $record.tweakName
        }
        Add-FOTransactionRecord -Transaction $transaction -TweakId $tweakId `
            -TweakName $recordName -Entries $entries

        $null = $results.Add([pscustomobject]@{
            TweakId = $tweakId; Outcome = 'Reverted'; Detail = "$($entries.Count) target(s)"
        })
    }

    if (-not $DryRun) {
        $null = Save-FOTransaction -Transaction $transaction
    }

    return [pscustomobject]@{
        Reverted     = @($results | Where-Object { $_.Outcome -eq 'Reverted' }).Count
        Results      = $results.ToArray()
        RebootNeeded = ($results.Count -gt 0)
    }
}

Export-ModuleMember -Function `
    Import-FOTweaks, Test-FOTweakDefinition, Get-FOTweaks, Get-FOTweakStatus, `
    Invoke-FOApply, Invoke-FORevert, Import-FOProtection, `
    Test-FOActionPermitted, Test-FOTweakApplicable
