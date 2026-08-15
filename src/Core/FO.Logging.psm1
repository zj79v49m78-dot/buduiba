<#
.SYNOPSIS
    FortressOne logging subsystem.
.DESCRIPTION
    Structured, levelled logging to both console and a rolling transcript file.
    Every mutating operation in FortressOne is logged before it is attempted and
    again after it completes, so a crashed or force-killed run can always be
    reconstructed from disk.
#>

Set-StrictMode -Version Latest

$script:LevelRank = @{
    'Trace' = 0
    'Debug' = 1
    'Info'  = 2
    'Warn'  = 3
    'Error' = 4
    'Fatal' = 5
}

$script:LevelColour = @{
    'Trace' = 'DarkGray'
    'Debug' = 'Gray'
    'Info'  = 'White'
    'Warn'  = 'Yellow'
    'Error' = 'Red'
    'Fatal' = 'Magenta'
}

function Initialize-FOLogging {
    <#
    .SYNOPSIS
        Opens the log file for this run. Called once by the launcher.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LogDirectory,
        [ValidateSet('Trace', 'Debug', 'Info', 'Warn', 'Error', 'Fatal')]
        [string] $MinimumLevel = 'Info'
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $script:LogPath = Join-Path $LogDirectory "fortressone-$stamp.log"
    $script:MinimumRank = $script:LevelRank[$MinimumLevel]
    $script:Initialized = $true

    # Retain the 30 most recent logs; a tweaking tool that silently eats a disk
    # over months is its own kind of performance problem.
    Get-ChildItem -LiteralPath $LogDirectory -Filter 'fortressone-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 30 |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Write-FOLog -Level Info -Message "FortressOne log opened at $script:LogPath"
    return $script:LogPath
}

function Write-FOLog {
    <#
    .SYNOPSIS
        Writes one structured log record.
    .PARAMETER Data
        Optional hashtable of structured fields appended as key=value pairs.
        Used to record tweak ids, registry paths and prior values.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Trace', 'Debug', 'Info', 'Warn', 'Error', 'Fatal')]
        [string] $Level = 'Info',
        [hashtable] $Data,
        [switch] $NoConsole
    )

    $rank = $script:LevelRank[$Level]
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')

    $suffix = ''
    if ($Data -and $Data.Count -gt 0) {
        $pairs = foreach ($key in ($Data.Keys | Sort-Object)) {
            $value = $Data[$key]
            if ($null -eq $value) { $value = '<null>' }
            "$key=$value"
        }
        $suffix = ' | ' + ($pairs -join ' ')
    }

    $line = "[$timestamp] [$($Level.ToUpperInvariant().PadRight(5))] $Message$suffix"

    # Always persist to disk regardless of console verbosity. The file is the
    # forensic record; the console is a convenience.
    if ($script:Initialized) {
        try {
            Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch {
            # Logging must never be the thing that kills the run.
            Write-Host "[logging failure] $($_.Exception.Message)" -ForegroundColor DarkRed
        }
    }

    if (-not $NoConsole -and $rank -ge $script:MinimumRank) {
        Write-Host $line -ForegroundColor $script:LevelColour[$Level]
    }
}

function Get-FOLogPath {
    if ($script:Initialized) { return $script:LogPath }
    return $null
}

$script:Initialized = $false
$script:MinimumRank = 2
$script:LogPath = $null

Export-ModuleMember -Function Initialize-FOLogging, Write-FOLog, Get-FOLogPath
