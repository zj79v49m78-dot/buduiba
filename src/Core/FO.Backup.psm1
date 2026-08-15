<#
.SYNOPSIS
    System-level safety net: restore points and registry exports.
.DESCRIPTION
    The journal can undo everything FortressOne does. These backups exist for
    everything FortressOne did NOT do — a Windows update that lands badly, a
    driver installed the same afternoon, or the user editing something manually
    after the fact. Defence in depth: the journal is the precise instrument, the
    restore point is the blunt one.
#>

Set-StrictMode -Version Latest

function New-FORestorePoint {
    <#
    .SYNOPSIS
        Creates a System Restore point, enabling protection first if required.
    #>
    [CmdletBinding()]
    param([string] $Description = 'FortressOne - before applying tweaks')

    $drive = $env:SystemDrive

    try {
        # System Protection is off by default on many installs, which is why
        # "just make a restore point first" so often silently does nothing.
        $enabled = $false
        try {
            $shadow = Get-CimInstance -ClassName 'Win32_ShadowCopy' -ErrorAction SilentlyContinue
            $status = vssadmin list shadowstorage 2>&1
            $enabled = ($LASTEXITCODE -eq 0)
        } catch { }

        Write-FOLog -Level Info -Message 'Ensuring System Protection is enabled...'
        Enable-ComputerRestore -Drive $drive -ErrorAction SilentlyContinue

        # Windows rate-limits restore points to one per 24h by default. Relax it
        # so a point is actually created when the user asks for one.
        $sr = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $priorFrequency = Get-FORegistryState -Path $sr -Name 'SystemRestorePointCreationFrequency'
        Set-FORegistryState -Path $sr -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type DWord

        Write-FOLog -Level Info -Message 'Creating restore point (this can take a minute)...'
        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop

        # Put the frequency setting back the way it was.
        if ($priorFrequency.Exists) {
            Set-FORegistryState -Path $sr -Name 'SystemRestorePointCreationFrequency' -Value $priorFrequency.Value -Type DWord
        } else {
            Remove-ItemProperty -LiteralPath $sr -Name 'SystemRestorePointCreationFrequency' -Force -ErrorAction SilentlyContinue
        }

        Write-FOLog -Level Info -Message 'Restore point created.'
        return $true
    } catch {
        Write-FOLog -Level Warn -Message 'Could not create a restore point' -Data @{ error = $_.Exception.Message }
        return $false
    }
}

function Export-FORegistryBackup {
    <#
    .SYNOPSIS
        Exports the registry hives FortressOne touches to .reg files.
    #>
    [CmdletBinding()]
    param([string] $Label = 'manual')

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dir = Join-Path $Global:FO.DataRoot "backups\registry\$Label-$stamp"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $hives = @(
        @{ Key = 'HKLM\SYSTEM\CurrentControlSet\Control';                        File = 'control.reg' }
        @{ Key = 'HKLM\SYSTEM\CurrentControlSet\Services';                       File = 'services.reg' }
        @{ Key = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia'; File = 'multimedia.reg' }
        @{ Key = 'HKLM\SOFTWARE\Policies';                                       File = 'policies-hklm.reg' }
        @{ Key = 'HKCU\Software\Microsoft\Windows\CurrentVersion';               File = 'currentversion-hkcu.reg' }
        @{ Key = 'HKCU\System\GameConfigStore';                                  File = 'gameconfigstore.reg' }
    )

    $exported = 0
    foreach ($hive in $hives) {
        $target = Join-Path $dir $hive.File
        $null = reg export $hive.Key $target /y 2>&1
        if ($LASTEXITCODE -eq 0) {
            $exported++
        } else {
            Write-FOLog -Level Warn -Message 'Registry export failed for a hive' -Data @{ key = $hive.Key }
        }
    }

    Write-FOLog -Level Info -Message 'Registry backup complete' -Data @{ path = $dir; hives = $exported }
    return $dir
}

function Get-FOBackupHistory {
    [CmdletBinding()]
    param()

    $root = Join-Path $Global:FO.DataRoot 'backups'
    if (-not (Test-Path -LiteralPath $root)) { return @() }

    Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 1 -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            [pscustomobject]@{
                Name     = $_.Name
                Type     = $_.Parent.Name
                Created  = $_.LastWriteTime
                Path     = $_.FullName
                SizeMb   = [math]::Round((Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                            Measure-Object -Property Length -Sum).Sum / 1MB, 2)
            }
        }
}

Export-ModuleMember -Function New-FORestorePoint, Export-FORegistryBackup, Get-FOBackupHistory
