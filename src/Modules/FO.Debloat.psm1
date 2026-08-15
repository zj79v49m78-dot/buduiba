<#
.SYNOPSIS
    Application, startup and package inventory and removal.
.DESCRIPTION
    THE HONEST POSITION ON REVERSIBILITY
    ------------------------------------
    The rest of FortressOne can undo everything it does, because every change is
    a setting whose prior value was captured. Removal is different, and this
    module does not pretend otherwise. Three categories, three levels of undo:

      Startup entries    FULLY REVERSIBLE. These are registry values and
                         scheduled tasks; the standard journal handles them and
                         disabling is preferred over deleting.

      Store (Appx) apps  REINSTALLABLE, not revertible. Removing the package
                         deletes it. Most can be reinstalled from the Store, and
                         provisioned ones can often be re-registered from the
                         system image. FortressOne records the exact package
                         identity of everything it removes so you know precisely
                         what to put back.

      Desktop (Win32)    NOT REVERSIBLE BY THIS TOOL. Uninstalling runs the
                         program's own uninstaller. FortressOne will show you
                         what is installed, size it, and tell you what is safe
                         to remove -- but it deliberately does not run mass
                         silent uninstalls. See the note below.

    WHY THERE IS NO "REMOVE EVERYTHING" BUTTON
    ------------------------------------------
    Not squeamishness -- the veto list exists precisely so aggressive removal is
    survivable. The reason is that a blind sweep cannot distinguish a redundant
    vendor utility from the Visual C++ runtime that Fortnite links against, the
    chipset package that governs your USB and PCIe behaviour, or the driver
    package your controller enumerates through. Removing those does not make the
    machine leaner; it makes it a machine that no longer runs Fortnite.

    So: the inventory is complete, the scoring is aggressive, the protection
    list is short and specific, and the decision is presented rather than
    assumed. That gets you the same stripped-down result without the failure
    mode where you finish the process and the game will not start.
#>

Set-StrictMode -Version Latest

function Get-FOInstalledInventory {
    <#
    .SYNOPSIS
        Enumerates every installed application from all three sources.
    #>
    [CmdletBinding()]
    param()

    Write-FOLog -Level Info -Message 'Building installed application inventory...'
    $items = [System.Collections.ArrayList]::new()

    # --- Win32 desktop applications (both registry views) -------------------
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    foreach ($root in $uninstallKeys) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($key in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            try {
                $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            } catch { continue }

            if ((-not (Test-FOHasProperty -InputObject $props -Name 'DisplayName'))) { continue }
            if ([string]::IsNullOrWhiteSpace($props.DisplayName)) { continue }

            # Skip update entries and system components, which are not really
            # "applications" and clutter the list badly.
            if ((Test-FOHasProperty -InputObject $props -Name 'SystemComponent') -and $props.SystemComponent -eq 1) { continue }
            if ($props.DisplayName -match '^(Security Update|Update for|Hotfix)') { continue }

            $sizeMb = 0
            if ((Test-FOHasProperty -InputObject $props -Name 'EstimatedSize') -and $props.EstimatedSize) {
                $sizeMb = [math]::Round($props.EstimatedSize / 1024, 1)
            }

            $null = $items.Add([pscustomobject]@{
                Type            = 'Win32'
                Name            = $props.DisplayName
                Publisher       = if ((Test-FOHasProperty -InputObject $props -Name 'Publisher')) { $props.Publisher } else { $null }
                Version         = if ((Test-FOHasProperty -InputObject $props -Name 'DisplayVersion')) { $props.DisplayVersion } else { $null }
                SizeMb          = $sizeMb
                Identifier      = $key.PSChildName
                UninstallString = if ((Test-FOHasProperty -InputObject $props -Name 'UninstallString')) { $props.UninstallString } else { $null }
                Reversible      = $false
            })
        }
    }

    # --- Store (Appx) packages ----------------------------------------------
    try {
        foreach ($pkg in (Get-AppxPackage -ErrorAction Stop)) {
            if ($pkg.IsFramework) { continue }

            $null = $items.Add([pscustomobject]@{
                Type            = 'Appx'
                Name            = $pkg.Name
                Publisher       = $pkg.Publisher
                Version         = [string]$pkg.Version
                SizeMb          = 0
                Identifier      = $pkg.PackageFullName
                UninstallString = $null
                Reversible      = $true
            })
        }
    } catch {
        Write-FOLog -Level Warn -Message 'Appx enumeration failed' -Data @{ error = $_.Exception.Message }
    }

    Write-FOLog -Level Info -Message 'Inventory complete' -Data @{ count = $items.Count }
    return @($items | Sort-Object Type, Name)
}

function Get-FOStartupInventory {
    <#
    .SYNOPSIS
        Enumerates everything configured to launch at sign-in.
    #>
    [CmdletBinding()]
    param()

    $items = [System.Collections.ArrayList]::new()

    $runKeys = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                Scope = 'Machine' }
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';    Scope = 'Machine (32-bit)' }
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                Scope = 'User' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';            Scope = 'Machine (once)' }
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';            Scope = 'User (once)' }
    )

    foreach ($entry in $runKeys) {
        if (-not (Test-Path -LiteralPath $entry.Path)) { continue }

        try {
            $key = Get-Item -LiteralPath $entry.Path -ErrorAction Stop
            foreach ($name in $key.GetValueNames()) {
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $null = $items.Add([pscustomobject]@{
                    Source      = 'Registry'
                    Scope       = $entry.Scope
                    Name        = $name
                    Command     = [string]$key.GetValue($name)
                    RegistryPath = $entry.Path
                    Reversible  = $true
                })
            }
        } catch { }
    }

    # Startup folders
    foreach ($folder in @(
        [Environment]::GetFolderPath('Startup'),
        [Environment]::GetFolderPath('CommonStartup')
    )) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) {
            $null = $items.Add([pscustomobject]@{
                Source       = 'StartupFolder'
                Scope        = $folder
                Name         = $file.Name
                Command      = $file.FullName
                RegistryPath = $null
                Reversible   = $true
            })
        }
    }

    return @($items)
}

function Get-FOBloatAssessment {
    <#
    .SYNOPSIS
        Scores every installed item against the catalog and the protection list.
    .DESCRIPTION
        Verdicts:
          Protected  -- on the veto list. Will not be removed under any tier.
          Keep       -- recognised as useful or as a dependency.
          Bloat      -- recognised as removable with no impact on the game.
          Review     -- unrecognised. YOU decide. Defaulting these to "remove"
                       is exactly how debloat scripts break machines, so they
                       are never auto-selected.
    #>
    [CmdletBinding()]
    param([array] $Inventory)

    if (-not $Inventory) { $Inventory = @(Get-FOInstalledInventory) }

    $catalogPath = Join-Path $Global:FO.AppRoot 'data\bloat-catalog.json'
    $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $protection = Import-FOProtection

    $assessed = foreach ($item in $Inventory) {
        $verdict = 'Review'
        $reason = 'Not recognised. FortressOne will not guess about software it does not know -- decide this one yourself.'

        # Protection wins over everything else.
        foreach ($guard in $protection.applications) {
            if ($item.Name -like $guard.match) {
                $verdict = 'Protected'
                $reason = $guard.reason
                break
            }
        }

        if ($verdict -eq 'Review') {
            foreach ($known in $catalog.bloat) {
                if ($item.Name -like $known.match) {
                    $verdict = 'Bloat'
                    $reason = $known.reason
                    break
                }
            }
        }

        if ($verdict -eq 'Review') {
            foreach ($known in $catalog.keep) {
                if ($item.Name -like $known.match) {
                    $verdict = 'Keep'
                    $reason = $known.reason
                    break
                }
            }
        }

        [pscustomobject]@{
            Type       = $item.Type
            Name       = $item.Name
            Publisher  = $item.Publisher
            SizeMb     = $item.SizeMb
            Identifier = $item.Identifier
            Verdict    = $verdict
            Reason     = $reason
            Reversible = $item.Reversible
            UninstallString = $item.UninstallString
        }
    }

    return @($assessed)
}

function Remove-FOAppxPackage {
    <#
    .SYNOPSIS
        Removes Store packages, recording exactly what was removed.
    .DESCRIPTION
        Writes a removal manifest before touching anything, so you always have a
        precise record of what to reinstall. Removal is not journal-revertible --
        this manifest is the recovery path, and it is written first for the same
        reason the journal is written before any registry write.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [array] $Packages,
        [switch] $AllUsers,
        [switch] $DryRun
    )

    $protection = Import-FOProtection
    $results = [System.Collections.ArrayList]::new()
    $manifest = [System.Collections.ArrayList]::new()

    foreach ($pkg in $Packages) {
        # Re-check protection at removal time. The assessment could have been
        # produced minutes ago; the veto is cheap and this is destructive.
        $vetoed = $false
        foreach ($guard in $protection.applications) {
            if ($pkg.Name -like $guard.match) {
                $null = $results.Add([pscustomobject]@{
                    Name = $pkg.Name; Outcome = 'Vetoed'; Detail = $guard.reason
                })
                $vetoed = $true
                break
            }
        }
        if ($vetoed) { continue }

        if ($DryRun) {
            $null = $results.Add([pscustomobject]@{
                Name = $pkg.Name; Outcome = 'WouldRemove'; Detail = $pkg.Identifier
            })
            continue
        }

        $null = $manifest.Add([ordered]@{
            name            = $pkg.Name
            packageFullName = $pkg.Identifier
            removedUtc      = (Get-Date).ToUniversalTime().ToString('o')
            reinstall       = "Get-AppxPackage -AllUsers -Name '$($pkg.Name)' | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register `"`$(`$_.InstallLocation)\AppXManifest.xml`" }"
        })
    }

    if ($DryRun) { return $results.ToArray() }

    # Manifest to disk BEFORE removal, same ordering principle as the journal.
    if ($manifest.Count -gt 0) {
        $manifestDir = Join-Path $Global:FO.DataRoot 'removals'
        if (-not (Test-Path -LiteralPath $manifestDir)) {
            New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
        }
        $manifestPath = Join-Path $manifestDir "appx-removal-$((Get-Date).ToString('yyyyMMdd-HHmmss')).json"
        Write-FOAtomicJson -Path $manifestPath -Object ([ordered]@{
            schemaVersion = 1
            note          = 'Packages removed by FortressOne. The reinstall command for each is included. Most can also simply be reinstalled from the Microsoft Store.'
            packages      = $manifest.ToArray()
        })
        Write-FOLog -Level Info -Message 'Removal manifest written' -Data @{ path = $manifestPath; count = $manifest.Count }
    }

    foreach ($record in $manifest) {
        try {
            Remove-AppxPackage -Package $record.packageFullName -ErrorAction Stop
            Write-FOLog -Level Info -Message "Removed Appx package" -Data @{ package = $record.name }
            $null = $results.Add([pscustomobject]@{
                Name = $record.name; Outcome = 'Removed'; Detail = $record.packageFullName
            })

            if ($AllUsers) {
                Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -eq $record.name } |
                    ForEach-Object {
                        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
                    }
            }
        } catch {
            Write-FOLog -Level Warn -Message 'Appx removal failed' -Data @{ package = $record.name; error = $_.Exception.Message }
            $null = $results.Add([pscustomobject]@{
                Name = $record.name; Outcome = 'Failed'; Detail = $_.Exception.Message
            })
        }
    }

    return $results.ToArray()
}

function New-FOStartupDisableTweak {
    <#
    .SYNOPSIS
        Builds a synthetic tweak that removes selected startup registry entries.
    .DESCRIPTION
        Goes through the standard engine, so the prior command line is journaled
        and the entry can be restored exactly. This is why startup cleanup is
        the one part of debloating that is genuinely, fully reversible.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array] $StartupItems)

    $actions = foreach ($item in $StartupItems) {
        if (-not $item.RegistryPath) { continue }
        [pscustomobject]@{
            provider = 'registry'
            path     = $item.RegistryPath
            name     = $item.Name
            type     = 'String'
            value    = $null
        }
    }

    $actions = @($actions)
    if ($actions.Count -eq 0) { return $null }

    return [pscustomobject]@{
        id             = 'dyn.startup.disable'
        name           = "Remove $($actions.Count) startup entr(ies)"
        category       = 'debloat'
        risk           = 'low'
        tier           = 'core'
        impact         = 'medium'
        requiresReboot = $false
        rationale      = "Removes these startup entries: $(($StartupItems | Select-Object -ExpandProperty Name) -join ', '). Each one is a process that starts with Windows, occupies memory and competes for CPU during the launch window. The original command line for each is captured in the journal, so restoring them puts back the exact value that was there."
        actions        = $actions
        applicable     = $true
        inapplicableReason = $null
        sourceFile     = '<dynamic>'
    }
}

function Get-FODebloatReport {
    [CmdletBinding()]
    param()

    $assessment = @(Get-FOBloatAssessment)
    $startup = @(Get-FOStartupInventory)

    $lines = [System.Collections.ArrayList]::new()
    $null = $lines.Add('DEBLOAT ASSESSMENT')
    $null = $lines.Add('=' * 72)

    foreach ($verdict in @('Bloat', 'Review', 'Keep', 'Protected')) {
        $group = @($assessment | Where-Object { $_.Verdict -eq $verdict })
        $null = $lines.Add('')
        $null = $lines.Add("$verdict ($($group.Count))")
        $null = $lines.Add('-' * 72)

        if ($group.Count -eq 0) {
            $null = $lines.Add('  (none)')
            continue
        }

        foreach ($item in ($group | Sort-Object Name)) {
            $size = if ($item.SizeMb -gt 0) { "$($item.SizeMb) MB" } else { '' }
            $null = $lines.Add(('  {0,-6} {1,-44} {2,10}' -f $item.Type, $item.Name.Substring(0, [math]::Min(44, $item.Name.Length)), $size))
        }
    }

    $null = $lines.Add('')
    $null = $lines.Add("STARTUP ENTRIES ($($startup.Count))")
    $null = $lines.Add('-' * 72)
    foreach ($item in $startup) {
        $null = $lines.Add(('  {0,-28} {1}' -f $item.Name.Substring(0, [math]::Min(28, $item.Name.Length)), $item.Scope))
    }

    $null = $lines.Add('')
    $null = $lines.Add('NOTES ON REVERSIBILITY')
    $null = $lines.Add('-' * 72)
    foreach ($note in @(
        'Startup entries are fully reversible -- the exact command line is journaled.',
        'Store apps are recorded to a removal manifest with reinstall commands, but removal itself is not undoable from the journal.',
        'Desktop applications are listed and assessed but NOT removed automatically. Uninstall the ones you agree with through Settings, so their own uninstallers run properly and leave the machine consistent.'
    )) {
        foreach ($wrapped in (Split-FOText -Width 68 -Text $note)) {
            $null = $lines.Add("  $wrapped")
        }
    }

    return ($lines -join [Environment]::NewLine)
}

Export-ModuleMember -Function `
    Get-FOInstalledInventory, Get-FOStartupInventory, Get-FOBloatAssessment, `
    Remove-FOAppxPackage, New-FOStartupDisableTweak, Get-FODebloatReport
