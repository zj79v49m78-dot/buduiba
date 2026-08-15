<#
.SYNOPSIS
    Device-level interrupt and power tuning, plus latency measurement.
.DESCRIPTION
    The tweaks in data/tweaks/ are static because their registry paths are the
    same on every machine. The changes in this module are not: they target
    device instance paths that are unique to your hardware, so they have to be
    discovered at runtime.

    Rather than writing a separate apply/revert path for them -- which would mean
    hand-written undo logic and all the risk that carries -- this module
    DISCOVERS the targets and then synthesises ordinary tweak objects, which are
    handed to the same Invoke-FOApply used by everything else.

    The result is that dynamically-targeted changes are journaled, dry-runnable,
    veto-checked and revertible through exactly the same code path as static
    ones. There is no second, less-tested revert implementation.
#>

Set-StrictMode -Version Latest

function Get-FOMsiCapableDevices {
    <#
    .SYNOPSIS
        Finds devices that support Message Signaled Interrupts.
    .DESCRIPTION
        Line-based interrupts are shared: the CPU takes an interrupt, then has to
        poll each device on the line to find out who raised it. MSI lets a device
        write its interrupt directly, removing the sharing and the polling.

        For a GPU this reduces the DPC latency spikes that show up as frametime
        stutter. For a USB host controller it reduces the delay between your
        controller sending an input report and the OS servicing it -- which is
        the specific thing you are chasing.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Display', 'USB', 'Net', 'All')]
        [string] $DeviceClass = 'All'
    )

    $classFilter = switch ($DeviceClass) {
        'Display' { @('Display') }
        'USB'     { @('USB') }
        'Net'     { @('Net') }
        default   { @('Display', 'USB', 'Net') }
    }

    $results = [System.Collections.ArrayList]::new()

    foreach ($class in $classFilter) {
        $devices = Get-PnpDevice -Class $class -Status OK -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -like 'PCI\*' }

        foreach ($device in $devices) {
            $msiPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
            $affinityPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)\Device Parameters\Interrupt Management\Affinity Policy"

            # The presence of the MessageSignaledInterruptProperties key is how
            # Windows advertises that the device's driver supports MSI at all.
            # Forcing MSISupported on hardware that does not support it can stop
            # the device working, so absence of this key is a hard skip.
            if (-not (Test-Path -LiteralPath $msiPath)) { continue }

            $current = Get-FORegistryState -Path $msiPath -Name 'MSISupported'
            $priority = Get-FORegistryState -Path $affinityPath -Name 'DevicePriority'

            $null = $results.Add([pscustomobject]@{
                FriendlyName  = $device.FriendlyName
                Class         = $class
                InstanceId    = $device.InstanceId
                MsiPath       = $msiPath
                AffinityPath  = $affinityPath
                MsiEnabled    = ($current.Exists -and [int]$current.Value -eq 1)
                MsiConfigured = $current.Exists
                DevicePriority = if ($priority.Exists) { [int]$priority.Value } else { $null }
            })
        }
    }

    return @($results)
}

function New-FOMsiTweak {
    <#
    .SYNOPSIS
        Builds a synthetic tweak enabling MSI mode on the given devices.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [array] $Devices,
        [switch] $SetHighPriority
    )

    $actions = [System.Collections.ArrayList]::new()
    $names = [System.Collections.ArrayList]::new()

    foreach ($device in $Devices) {
        $null = $actions.Add([pscustomobject]@{
            provider = 'registry'
            path     = $device.MsiPath
            name     = 'MSISupported'
            type     = 'DWord'
            value    = 1
        })

        # DevicePriority 3 marks the device's interrupts as high priority. This
        # is worthwhile on the GPU and the USB controller your pad is on; it is
        # deliberately opt-in because raising everything's priority raises
        # nothing's priority.
        if ($SetHighPriority) {
            $null = $actions.Add([pscustomobject]@{
                provider = 'registry'
                path     = $device.AffinityPath
                name     = 'DevicePriority'
                type     = 'DWord'
                value    = 3
            })
        }

        $null = $names.Add($device.FriendlyName)
    }

    return [pscustomobject]@{
        id             = 'dyn.msi.enable'
        name           = "Enable MSI mode on $($Devices.Count) device(s)"
        category       = 'latency'
        risk           = 'medium'
        tier           = 'core'
        impact         = 'high'
        requiresReboot = $true
        rationale      = "Enables Message Signaled Interrupts on: $($names -join ', '). Removes shared line-based interrupt handling, cutting DPC latency spikes for the GPU and shortening the path from a controller input report to the OS servicing it."
        actions        = $actions.ToArray()
        applicable     = $true
        inapplicableReason = $null
        sourceFile     = '<dynamic>'
    }
}

function Get-FOUsbPowerDevices {
    <#
    .SYNOPSIS
        Finds USB devices whose power management can be disabled.
    #>
    [CmdletBinding()]
    param()

    $results = [System.Collections.ArrayList]::new()

    $devices = Get-PnpDevice -Class 'USB' -Status OK -ErrorAction SilentlyContinue
    foreach ($device in $devices) {
        $paramPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)\Device Parameters"
        if (-not (Test-Path -LiteralPath $paramPath)) { continue }

        $enhanced = Get-FORegistryState -Path $paramPath -Name 'EnhancedPowerManagementEnabled'
        $selective = Get-FORegistryState -Path $paramPath -Name 'SelectiveSuspendEnabled'

        # Only devices that actually expose power management are interesting.
        if (-not $enhanced.Exists -and -not $selective.Exists) { continue }

        $null = $results.Add([pscustomobject]@{
            FriendlyName = $device.FriendlyName
            InstanceId   = $device.InstanceId
            ParamPath    = $paramPath
            EnhancedPm   = if ($enhanced.Exists) { [int]$enhanced.Value } else { $null }
            SelectiveSuspend = if ($selective.Exists) { [int]$selective.Value } else { $null }
            LooksLikeController = ($device.FriendlyName -match 'Controller|Gamepad|XBOX|GameSir|XInput|HID-compliant game')
        })
    }

    return @($results)
}

function New-FOUsbPowerTweak {
    <#
    .SYNOPSIS
        Builds a synthetic tweak disabling USB power management on given devices.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array] $Devices)

    $actions = [System.Collections.ArrayList]::new()

    foreach ($device in $Devices) {
        $null = $actions.Add([pscustomobject]@{
            provider = 'registry'; path = $device.ParamPath
            name = 'EnhancedPowerManagementEnabled'; type = 'DWord'; value = 0
        })
        $null = $actions.Add([pscustomobject]@{
            provider = 'registry'; path = $device.ParamPath
            name = 'SelectiveSuspendEnabled'; type = 'DWord'; value = 0
        })
        $null = $actions.Add([pscustomobject]@{
            provider = 'registry'; path = $device.ParamPath
            name = 'AllowIdleIrpInD3'; type = 'DWord'; value = 0
        })
    }

    return [pscustomobject]@{
        id             = 'dyn.usb.no-power-management'
        name           = "Disable USB power management on $($Devices.Count) device(s)"
        category       = 'input'
        risk           = 'low'
        tier           = 'core'
        impact         = 'high'
        requiresReboot = $true
        rationale      = 'Stops Windows suspending these USB endpoints when they look idle. For a wired controller this removes the wake delay on the first input after a pause, which is the classic cause of the pad feeling fine during continuous movement but mushy on the first press after standing still.'
        actions        = $actions.ToArray()
        applicable     = $true
        inapplicableReason = $null
        sourceFile     = '<dynamic>'
    }
}

function Measure-FOTimerResolution {
    <#
    .SYNOPSIS
        Measures the effective timer resolution by timing Sleep(1).
    .DESCRIPTION
        Reports what the system ACTUALLY delivers rather than what a registry
        value claims. Note for Windows 11: since Windows 10 2004, a timer
        resolution request affects only the requesting process, and Windows 11
        ignores requests from background processes entirely. That makes
        third-party "timer resolution" utilities largely a no-op on your OS --
        they raise resolution for themselves and nothing else.

        Fortnite requests high resolution for itself, which is what matters.
        This measurement exists to confirm that rather than to justify running a
        background tool that cannot help.
    #>
    [CmdletBinding()]
    param([int] $Samples = 40)

    $measurements = [System.Collections.ArrayList]::new()
    $sw = [System.Diagnostics.Stopwatch]::new()

    for ($i = 0; $i -lt $Samples; $i++) {
        $sw.Restart()
        [System.Threading.Thread]::Sleep(1)
        $sw.Stop()
        $null = $measurements.Add($sw.Elapsed.TotalMilliseconds)
    }

    $sorted = @($measurements | Sort-Object)
    $median = $sorted[[math]::Floor($sorted.Count / 2)]

    return [pscustomobject]@{
        MedianSleep1Ms = [math]::Round($median, 3)
        MinSleep1Ms    = [math]::Round($sorted[0], 3)
        MaxSleep1Ms    = [math]::Round($sorted[-1], 3)
        Interpretation = if ($median -lt 1.2) {
            'Effective resolution is around 1ms or better. Nothing to fix.'
        } elseif ($median -lt 2.0) {
            'Resolution is acceptable. Some background process is likely holding a 1ms request.'
        } else {
            "Sleep(1) is taking $([math]::Round($median,2))ms, suggesting the default ~15.6ms tick is in effect for this process. This is normal for a background script on Windows 11 and does not indicate a problem with the game, which requests its own resolution."
        }
    }
}

function Get-FOLatencyReport {
    [CmdletBinding()]
    param()

    $lines = [System.Collections.ArrayList]::new()
    $null = $lines.Add('DEVICE LATENCY DIAGNOSTIC')
    $null = $lines.Add('=' * 72)

    # --- MSI mode -----------------------------------------------------------
    $null = $lines.Add('')
    $null = $lines.Add('MSI (Message Signaled Interrupts)')
    $null = $lines.Add('-' * 72)

    $msiDevices = @(Get-FOMsiCapableDevices)
    if ($msiDevices.Count -eq 0) {
        $null = $lines.Add('  No MSI-capable PCI devices detected.')
    }
    foreach ($device in $msiDevices) {
        $state = if ($device.MsiEnabled) { 'MSI enabled' } else { 'line-based (MSI available)' }
        $null = $lines.Add(('  {0,-52} {1}' -f $device.FriendlyName.Substring(0, [math]::Min(52, $device.FriendlyName.Length)), $state))
    }

    $notEnabled = @($msiDevices | Where-Object { -not $_.MsiEnabled })
    if ($notEnabled.Count -gt 0) {
        $null = $lines.Add('')
        foreach ($wrapped in (Split-FOText -Width 68 -Text "$($notEnabled.Count) device(s) support MSI but are still using shared line-based interrupts. Enabling MSI on the GPU and the USB host controller is worth doing. Use the 'Apply device latency tweaks' option to do it -- it is journaled and revertible like everything else.")) {
            $null = $lines.Add("  $wrapped")
        }
    }

    # --- USB power ----------------------------------------------------------
    $null = $lines.Add('')
    $null = $lines.Add('USB power management')
    $null = $lines.Add('-' * 72)

    $usbDevices = @(Get-FOUsbPowerDevices)
    $poweredDown = @($usbDevices | Where-Object { $_.EnhancedPm -eq 1 -or $_.SelectiveSuspend -eq 1 })
    $controllers = @($usbDevices | Where-Object { $_.LooksLikeController })

    $null = $lines.Add("  USB devices exposing power management : $($usbDevices.Count)")
    $null = $lines.Add("  Currently allowed to power down       : $($poweredDown.Count)")
    if ($controllers.Count -gt 0) {
        $null = $lines.Add('')
        $null = $lines.Add('  Detected as game controllers:')
        foreach ($c in $controllers) {
            $flag = if ($c.EnhancedPm -eq 1 -or $c.SelectiveSuspend -eq 1) { 'CAN POWER DOWN -- fix this' } else { 'power management already off' }
            $null = $lines.Add("    - $($c.FriendlyName): $flag")
        }
    }

    # --- Timer --------------------------------------------------------------
    $null = $lines.Add('')
    $null = $lines.Add('Timer resolution')
    $null = $lines.Add('-' * 72)
    $timer = Measure-FOTimerResolution
    $null = $lines.Add("  Sleep(1) median: $($timer.MedianSleep1Ms) ms (min $($timer.MinSleep1Ms), max $($timer.MaxSleep1Ms))")
    foreach ($wrapped in (Split-FOText -Width 68 -Text $timer.Interpretation)) {
        $null = $lines.Add("  $wrapped")
    }

    return ($lines -join [Environment]::NewLine)
}

Export-ModuleMember -Function `
    Get-FOMsiCapableDevices, New-FOMsiTweak, `
    Get-FOUsbPowerDevices, New-FOUsbPowerTweak, `
    Measure-FOTimerResolution, Get-FOLatencyReport
