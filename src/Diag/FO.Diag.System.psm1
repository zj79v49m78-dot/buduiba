<#
.SYNOPSIS
    Hardware and platform inventory.
.DESCRIPTION
    Populates $Global:FO.System, which the engine consults to decide which
    tweaks are applicable to this specific machine. Detection runs once at
    startup so every later decision is made against real facts rather than
    assumptions about what the user has.
#>

Set-StrictMode -Version Latest

function Initialize-FOSystemInfo {
    [CmdletBinding()]
    param()

    Write-FOLog -Level Info -Message 'Collecting system inventory...'

    $info = [ordered]@{
        CollectedUtc     = (Get-Date).ToUniversalTime().ToString('o')
        ComputerName     = $env:COMPUTERNAME
        OsCaption        = $null
        OsBuild          = $null
        OsDisplayVersion = $null
        IsWindows11      = $false
        IsLaptop         = $false
        Cpu              = $null
        CpuCores         = 0
        CpuThreads       = 0
        CpuMaxClockMhz   = 0
        Gpus             = @()
        HasNvidiaGpu     = $false
        NvidiaDriver     = $null
        RamTotalGb       = 0
        RamSticks        = @()
        RamSpeedMhz      = 0
        Motherboard      = $null
        BiosVersion      = $null
        Displays         = @()
        HasWiredAdapter  = $false
        PrimaryAdapter   = $null
        SystemDriveType  = 'Unknown'
        FortniteDrive    = $null
        PowerPlan        = $null
        SecureBoot       = $null
        VbsRunning       = $null
        TamperProtection = $null
    }

    # --- Operating system ---------------------------------------------------
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $info.OsCaption = $os.Caption
        $info.OsBuild = $os.BuildNumber
        $info.RamTotalGb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)

        # Build 22000 is the Windows 11 boundary. The Caption string is not a
        # reliable discriminator because early Win11 builds reported oddly.
        $info.IsWindows11 = ([int]$os.BuildNumber -ge 22000)

        $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $info.OsDisplayVersion = (Get-ItemProperty -LiteralPath $cv -Name 'DisplayVersion' -ErrorAction SilentlyContinue).DisplayVersion
    } catch {
        Write-FOLog -Level Warn -Message 'OS inventory failed' -Data @{ error = $_.Exception.Message }
    }

    # --- Chassis: desktop vs laptop ----------------------------------------
    try {
        $chassis = (Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes
        # 8-14 and 30-32 are the portable/laptop/tablet families.
        $portable = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
        $info.IsLaptop = @($chassis | Where-Object { $portable -contains $_ }).Count -gt 0
    } catch { }

    # --- CPU ----------------------------------------------------------------
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $info.Cpu = $cpu.Name.Trim()
        $info.CpuCores = $cpu.NumberOfCores
        $info.CpuThreads = $cpu.NumberOfLogicalProcessors
        $info.CpuMaxClockMhz = $cpu.MaxClockSpeed
    } catch { }

    # --- GPU ----------------------------------------------------------------
    try {
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction Stop
        $info.Gpus = @($gpus | ForEach-Object {
            [pscustomobject]@{
                Name          = $_.Name
                DriverVersion = $_.DriverVersion
                DriverDate    = $_.DriverDate
                VramGb        = if ($_.AdapterRAM -gt 0) { [math]::Round($_.AdapterRAM / 1GB, 1) } else { $null }
            }
        })
        $nvidia = $info.Gpus | Where-Object { $_.Name -match 'NVIDIA|GeForce|Quadro|RTX|GTX' } | Select-Object -First 1
        if ($nvidia) {
            $info.HasNvidiaGpu = $true
            $info.NvidiaDriver = $nvidia.DriverVersion
        }
    } catch { }

    # --- Memory -------------------------------------------------------------
    try {
        $sticks = Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop
        $info.RamSticks = @($sticks | ForEach-Object {
            [pscustomobject]@{
                Slot       = $_.DeviceLocator
                CapacityGb = [math]::Round($_.Capacity / 1GB, 0)
                SpeedMhz   = $_.Speed
                ConfiguredMhz = $_.ConfiguredClockSpeed
                Manufacturer  = $_.Manufacturer
            }
        })
        if ($info.RamSticks.Count -gt 0) {
            # ConfiguredClockSpeed is what the memory is ACTUALLY running at.
            # Speed is what the module is rated for. The gap between them is how
            # you detect XMP silently not being enabled.
            $info.RamSpeedMhz = ($info.RamSticks | Measure-Object -Property ConfiguredMhz -Maximum).Maximum
        }
    } catch { }

    # --- Board and BIOS -----------------------------------------------------
    try {
        $board = Get-CimInstance Win32_BaseBoard -ErrorAction Stop
        $info.Motherboard = "$($board.Manufacturer) $($board.Product)"
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $info.BiosVersion = "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))"
    } catch { }

    # --- Displays and refresh rate -----------------------------------------
    try {
        $modes = Get-CimInstance -Namespace 'root\wmi' -ClassName 'WmiMonitorListedSupportedSourceModes' -ErrorAction SilentlyContinue
        $current = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
            Where-Object { $_.CurrentRefreshRate -gt 0 }

        $info.Displays = @($current | ForEach-Object {
            [pscustomobject]@{
                Adapter           = $_.Name
                CurrentRefreshHz  = $_.CurrentRefreshRate
                MaxRefreshHz      = $_.MaxRefreshRate
                Horizontal        = $_.CurrentHorizontalResolution
                Vertical          = $_.CurrentVerticalResolution
            }
        })
    } catch { }

    # --- Network ------------------------------------------------------------
    try {
        $adapter = Get-FOPrimaryAdapter
        if ($adapter) {
            $info.HasWiredAdapter = ($adapter.MediaType -ne 'Native 802.11' -and $adapter.PhysicalMediaType -notmatch 'Wireless')
            $info.PrimaryAdapter = [pscustomobject]@{
                Name        = $adapter.Name
                Description = $adapter.InterfaceDescription
                LinkSpeed   = $adapter.LinkSpeed
                MacAddress  = $adapter.MacAddress
                Status      = [string]$adapter.Status
            }
        }
    } catch { }

    # --- Storage ------------------------------------------------------------
    try {
        $sysLetter = ($env:SystemDrive).TrimEnd(':')
        $partition = Get-Partition -DriveLetter $sysLetter -ErrorAction Stop
        $disk = Get-PhysicalDisk -ErrorAction Stop |
            Where-Object { $_.DeviceId -eq (Get-Disk -Number $partition.DiskNumber).Number }
        if ($disk) { $info.SystemDriveType = [string]$disk.MediaType }
    } catch { }

    # --- Power plan ---------------------------------------------------------
    try {
        $active = (powercfg /getactivescheme) 2>$null
        if ($active -match '\(([^)]+)\)\s*$') { $info.PowerPlan = $Matches[1] }
    } catch { }

    # --- Security posture (affects which tweaks will stick) -----------------
    try {
        $info.SecureBoot = (Confirm-SecureBootUEFI -ErrorAction SilentlyContinue)
    } catch { $info.SecureBoot = 'Unknown' }

    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' `
            -ClassName 'Win32_DeviceGuard' -ErrorAction Stop
        # SecurityServicesRunning containing 1 means credential guard, 2 means HVCI.
        $info.VbsRunning = ($dg.VirtualizationBasedSecurityStatus -eq 2)
    } catch { }

    # Tamper Protection silently reverts Defender registry changes. Knowing its
    # state up front lets the tool warn instead of quietly failing later.
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $info.TamperProtection = $mp.IsTamperProtected
    } catch { }

    $Global:FO.System = [pscustomobject]$info
    Write-FOLog -Level Info -Message 'System inventory complete' -Data @{
        cpu = $info.Cpu; gpu = ($info.Gpus | Select-Object -First 1).Name
        ram = "$($info.RamTotalGb)GB @ $($info.RamSpeedMhz)MHz"; os = $info.OsCaption
    }

    return $Global:FO.System
}

function Get-FOSystemReport {
    <#
    .SYNOPSIS
        Human-readable inventory with interpretation, not just a data dump.
    #>
    [CmdletBinding()]
    param()

    $s = $Global:FO.System
    $lines = [System.Collections.ArrayList]::new()

    $null = $lines.Add('SYSTEM INVENTORY')
    $null = $lines.Add('=' * 72)
    $null = $lines.Add("OS              : $($s.OsCaption) build $($s.OsBuild) ($($s.OsDisplayVersion))")
    $null = $lines.Add("CPU             : $($s.Cpu)")
    $null = $lines.Add("                  $($s.CpuCores) cores / $($s.CpuThreads) threads @ $($s.CpuMaxClockMhz) MHz")
    foreach ($gpu in $s.Gpus) {
        $null = $lines.Add("GPU             : $($gpu.Name) (driver $($gpu.DriverVersion))")
    }
    $null = $lines.Add("RAM             : $($s.RamTotalGb) GB running at $($s.RamSpeedMhz) MHz")
    foreach ($stick in $s.RamSticks) {
        $null = $lines.Add("                  $($stick.Slot): $($stick.CapacityGb)GB rated $($stick.SpeedMhz) / running $($stick.ConfiguredMhz)")
    }
    $null = $lines.Add("Motherboard     : $($s.Motherboard)")
    $null = $lines.Add("BIOS            : $($s.BiosVersion)")
    foreach ($d in $s.Displays) {
        $null = $lines.Add("Display         : $($d.Horizontal)x$($d.Vertical) @ $($d.CurrentRefreshHz) Hz (max reported $($d.MaxRefreshHz) Hz)")
    }
    if ($s.PrimaryAdapter) {
        $null = $lines.Add("Network         : $($s.PrimaryAdapter.Description)")
        $null = $lines.Add("                  link $($s.PrimaryAdapter.LinkSpeed), status $($s.PrimaryAdapter.Status)")
    }
    $null = $lines.Add("System drive    : $($s.SystemDriveType)")
    $null = $lines.Add("Power plan      : $($s.PowerPlan)")

    $null = $lines.Add('')
    $null = $lines.Add('FINDINGS')
    $null = $lines.Add('-' * 72)

    $findings = @(Get-FOSystemFindings)
    if ($findings.Count -eq 0) {
        $null = $lines.Add('  Nothing notable. Inventory looks as expected.')
    }
    foreach ($f in $findings) {
        $null = $lines.Add("  [$($f.Severity)] $($f.Title)")
        foreach ($wrapped in (Split-FOText -Text $f.Detail -Width 66)) {
            $null = $lines.Add("        $wrapped")
        }
        $null = $lines.Add('')
    }

    return ($lines -join [Environment]::NewLine)
}

function Get-FOSystemFindings {
    <#
    .SYNOPSIS
        Interprets the inventory and reports things that are actually wrong.
    #>
    [CmdletBinding()]
    param()

    $s = $Global:FO.System
    $findings = [System.Collections.ArrayList]::new()

    # --- Memory running below its rating (XMP not enabled) ------------------
    foreach ($stick in $s.RamSticks) {
        if ($stick.ConfiguredMhz -and $stick.SpeedMhz -and $stick.ConfiguredMhz -lt $stick.SpeedMhz) {
            $null = $findings.Add([pscustomobject]@{
                Severity = 'WARN'
                Title    = "Memory is running at $($stick.ConfiguredMhz) MHz but is rated for $($stick.SpeedMhz) MHz"
                Detail   = "XMP is not enabled, or is not applying. Fortnite is sensitive to memory latency and bandwidth, and running 3200 MHz memory at the JEDEC default of 2133 costs real frames -- commonly 5 to 10 percent of your 1% lows. Enable XMP Profile 1 in BIOS. This is free performance you have already paid for."
            })
            break
        }
    }

    # --- Only one memory channel populated ----------------------------------
    if ($s.RamSticks.Count -eq 1) {
        $null = $findings.Add([pscustomobject]@{
            Severity = 'WARN'
            Title    = 'Only one memory module detected -- running in single channel'
            Detail   = "Single-channel memory halves your memory bandwidth. This is one of the largest performance losses possible on an Intel platform and it affects 1% lows badly. If you have two 8GB sticks, make sure they are in the correct paired slots for your board (usually A2 and B2, the second and fourth slots from the CPU)."
        })
    }

    # --- Refresh rate not set to the panel maximum --------------------------
    foreach ($d in $s.Displays) {
        if ($d.MaxRefreshHz -and $d.CurrentRefreshHz -and $d.CurrentRefreshHz -lt $d.MaxRefreshHz) {
            $null = $findings.Add([pscustomobject]@{
                Severity = 'CRITICAL'
                Title    = "Display is running at $($d.CurrentRefreshHz) Hz but supports $($d.MaxRefreshHz) Hz"
                Detail   = "You are leaving refresh rate on the table, which directly costs you input latency regardless of how many frames the GPU produces. Fix in Settings, System, Display, Advanced display, Choose a refresh rate. This is the first thing to correct -- every other latency tweak is smaller than this."
            })
        }
    }

    # --- VBS running (Windows 11 CPU overhead) ------------------------------
    if ($s.IsWindows11 -and $s.VbsRunning -eq $true) {
        $null = $findings.Add([pscustomobject]@{
            Severity = 'WARN'
            Title    = 'Virtualisation Based Security is active'
            Detail   = "VBS and Memory Integrity impose a measurable CPU cost that lands hardest on 6-core parts under game load. The Windows 11 tweak pack can disable them. Understand that this is a genuine security trade-off, not a free win."
        })
    }

    # --- Tamper Protection blocking Defender tweaks -------------------------
    if ($s.TamperProtection -eq $true) {
        $null = $findings.Add([pscustomobject]@{
            Severity = 'INFO'
            Title    = 'Defender Tamper Protection is enabled'
            Detail   = "Any tweak that disables Defender through the registry will be silently reverted by Windows within minutes while this is on. FortressOne will not attempt to bypass it -- tools that defeat Tamper Protection behave indistinguishably from malware. If you genuinely want Defender off, turn Tamper Protection off manually in Windows Security first. The Defender exclusion tweak is a better option regardless."
        })
    }

    # --- Mechanical system drive --------------------------------------------
    if ($s.SystemDriveType -eq 'HDD') {
        $null = $findings.Add([pscustomobject]@{
            Severity = 'WARN'
            Title    = 'Windows is installed on a mechanical hard drive'
            Detail   = "This is the single biggest upgrade available to this machine and no software tweak substitutes for it. It also means you should NOT disable SysMain -- on a mechanical drive its prefetching genuinely helps. An SSD would improve load times, asset streaming hitches and general responsiveness more than everything else in this tool combined."
        })
    }

    # --- GPU-bound reality check --------------------------------------------
    $gpu = $s.Gpus | Select-Object -First 1
    if ($gpu -and $gpu.Name -match 'GTX 10[567]0|GTX 9|GTX 16') {
        $refresh = ($s.Displays | Measure-Object -Property CurrentRefreshHz -Maximum).Maximum
        if ($refresh -ge 200) {
            $null = $findings.Add([pscustomobject]@{
                Severity = 'CRITICAL'
                Title    = "$($gpu.Name) driving a $refresh Hz display -- you are GPU bound in real matches"
                Detail   = "This is almost certainly the root cause of your input delay. When the GPU sits at 99-100 percent utilisation, frames queue ahead of the display and every queued frame adds latency to your controller input. It explains exactly why Creative feels instant at 240 FPS while a real match feels awful at 200: in Creative the GPU has headroom and the queue stays empty. THE FIX IS COUNTERINTUITIVE -- cap your frame rate BELOW what the GPU can sustain, around 150-160, so utilisation stays under about 97 percent. You will see a lower FPS number and dramatically better input latency. Combine with Reflex set to On plus Boost. Run the Fortnite settings module for the full configuration."
            })
        }
    }

    return $findings.ToArray()
}

function Split-FOText {
    <#
    .SYNOPSIS
        Word-wraps text for console report output.
    #>
    param([string] $Text, [int] $Width = 70)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $words = $Text -split '\s+'
    $lines = [System.Collections.ArrayList]::new()
    $current = ''

    foreach ($word in $words) {
        if (($current.Length + $word.Length + 1) -gt $Width) {
            if ($current) { $null = $lines.Add($current) }
            $current = $word
        } else {
            $current = if ($current) { "$current $word" } else { $word }
        }
    }
    if ($current) { $null = $lines.Add($current) }

    return $lines.ToArray()
}

Export-ModuleMember -Function Initialize-FOSystemInfo, Get-FOSystemReport, Get-FOSystemFindings, Split-FOText
