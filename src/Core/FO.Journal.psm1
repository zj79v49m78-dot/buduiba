<#
.SYNOPSIS
    FortressOne state journal -- the mechanism that makes every change reversible.
.DESCRIPTION
    The journal is the single most important component in FortressOne.

    FortressOne never hand-writes "undo" logic for individual tweaks. Instead,
    before any mutation, the engine reads the CURRENT state of the target and
    hands it to the journal. Reverting is then a purely mechanical operation:
    replay the recorded prior states in reverse order.

    This means a tweak cannot be "unrevertible by mistake" -- the revert path is
    the same code for every tweak, and it is exercised on every tweak that has
    ever been applied. There is no per-tweak undo function to forget to write,
    get wrong, or let drift out of sync with the apply path.

    Two facts are recorded for every target:
      PriorExists : did the target exist at all before we touched it?
      PriorValue  : if it existed, what was it?

    That distinction matters enormously. Restoring a registry value to 0 is NOT
    the same as deleting a value that never existed -- Windows and drivers behave
    differently for "absent" versus "present and zero". Conflating the two is the
    most common way tweaking tools leave systems permanently altered while
    claiming to have restored them.

    Storage layout (under %ProgramData%\FortressOne\journal):
      applied.json      Master index of every tweak currently applied.
      tx-<guid>.json    Immutable per-transaction record, never rewritten.
#>

Set-StrictMode -Version Latest

$script:SchemaVersion = 2

function Get-FOJournalRoot {
    return (Join-Path $Global:FO.DataRoot 'journal')
}

function Initialize-FOJournal {
    [CmdletBinding()]
    param()

    $root = Get-FOJournalRoot
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }

    $indexPath = Join-Path $root 'applied.json'
    if (-not (Test-Path -LiteralPath $indexPath)) {
        $seed = [ordered]@{
            schemaVersion = $script:SchemaVersion
            createdUtc    = (Get-Date).ToUniversalTime().ToString('o')
            machine       = $env:COMPUTERNAME
            tweaks        = @{}
        }
        Write-FOAtomicJson -Path $indexPath -Object $seed
        Write-FOLog -Level Info -Message 'Created new state journal' -Data @{ path = $indexPath }
    }

    return $root
}

function Write-FOAtomicJson {
    <#
    .SYNOPSIS
        Writes JSON via write-temp-then-replace so a crash mid-write cannot
        corrupt the journal and strand the user with unrevertible changes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Object
    )

    $temp = "$Path.tmp"
    $json = $Object | ConvertTo-Json -Depth 12

    Set-Content -LiteralPath $temp -Value $json -Encoding UTF8 -Force

    # Validate the temp file parses before it is allowed to replace the real one.
    try {
        $null = Get-Content -LiteralPath $temp -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw "Refusing to commit malformed journal JSON to '$Path': $($_.Exception.Message)"
    }

    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Read-FOJournalIndex {
    [CmdletBinding()]
    param()

    $indexPath = Join-Path (Get-FOJournalRoot) 'applied.json'
    if (-not (Test-Path -LiteralPath $indexPath)) {
        Initialize-FOJournal | Out-Null
    }

    try {
        $raw = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 -ErrorAction Stop
        return ($raw | ConvertFrom-Json)
    } catch {
        # A corrupt index is recoverable: the immutable tx-*.json files are the
        # real record. Rebuild rather than lose the ability to revert.
        Write-FOLog -Level Error -Message 'Journal index unreadable; rebuilding from transaction files' -Data @{ error = $_.Exception.Message }
        return (Restore-FOJournalIndex)
    }
}

function Restore-FOJournalIndex {
    <#
    .SYNOPSIS
        Rebuilds applied.json by replaying every immutable transaction file.
    #>
    [CmdletBinding()]
    param()

    $root = Get-FOJournalRoot
    $rebuilt = [ordered]@{
        schemaVersion = $script:SchemaVersion
        createdUtc    = (Get-Date).ToUniversalTime().ToString('o')
        machine       = $env:COMPUTERNAME
        rebuilt       = $true
        tweaks        = @{}
    }

    $txFiles = Get-ChildItem -LiteralPath $root -Filter 'tx-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime

    foreach ($file in $txFiles) {
        try {
            $tx = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-FOLog -Level Warn -Message 'Skipping unreadable transaction file' -Data @{ file = $file.Name }
            continue
        }

        foreach ($record in $tx.records) {
            if ($tx.operation -eq 'apply') {
                $rebuilt.tweaks[$record.tweakId] = [ordered]@{
                    appliedUtc    = $tx.startedUtc
                    transactionId = $tx.transactionId
                    entries       = $record.entries
                }
            } elseif ($tx.operation -eq 'revert') {
                $rebuilt.tweaks.Remove($record.tweakId)
            }
        }
    }

    Write-FOAtomicJson -Path (Join-Path $root 'applied.json') -Object $rebuilt
    Write-FOLog -Level Info -Message 'Journal index rebuilt' -Data @{ tweaks = $rebuilt.tweaks.Count }
    return ($rebuilt | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
}

function New-FOTransaction {
    <#
    .SYNOPSIS
        Opens an in-memory transaction. Nothing touches disk until Save.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('apply', 'revert')]
        [string] $Operation,
        [string] $Description = ''
    )

    return [pscustomobject]@{
        schemaVersion = $script:SchemaVersion
        transactionId = [guid]::NewGuid().ToString()
        operation     = $Operation
        description   = $Description
        startedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        completedUtc  = $null
        machine       = $env:COMPUTERNAME
        osBuild       = [string][System.Environment]::OSVersion.Version
        records       = [System.Collections.ArrayList]::new()
    }
}

function Add-FOTransactionRecord {
    <#
    .SYNOPSIS
        Records the full prior state of one tweak's targets.
    .PARAMETER Entries
        Array of hashtables, each: provider, target, priorExists, priorValue,
        newValue, and any provider-specific metadata needed to reverse it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Transaction,
        [Parameter(Mandatory)] [string] $TweakId,
        [Parameter(Mandatory)] [string] $TweakName,
        [Parameter(Mandatory)] [array]  $Entries
    )

    $null = $Transaction.records.Add([pscustomobject]@{
        tweakId   = $TweakId
        tweakName = $TweakName
        entries   = $Entries
    })
}

function Save-FOTransaction {
    <#
    .SYNOPSIS
        Commits a transaction to disk and updates the master applied index.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Transaction
    )

    if ($Transaction.records.Count -eq 0) {
        Write-FOLog -Level Debug -Message 'Transaction had no records; nothing committed'
        return $null
    }

    $root = Initialize-FOJournal
    $Transaction.completedUtc = (Get-Date).ToUniversalTime().ToString('o')

    # The transaction file is written FIRST and never modified again. If the
    # index update below fails, the record still exists and can be replayed.
    $txPath = Join-Path $root "tx-$($Transaction.transactionId).json"
    Write-FOAtomicJson -Path $txPath -Object $Transaction

    $index = Read-FOJournalIndex

    # ConvertFrom-Json yields PSCustomObject; convert the tweaks map to a
    # hashtable so entries can be added and removed.
    $tweaks = @{}
    if ($index.PSObject.Properties.Name -contains 'tweaks' -and $index.tweaks) {
        foreach ($prop in $index.tweaks.PSObject.Properties) {
            $tweaks[$prop.Name] = $prop.Value
        }
    }

    foreach ($record in $Transaction.records) {
        if ($Transaction.operation -eq 'apply') {
            $tweaks[$record.tweakId] = [ordered]@{
                appliedUtc    = $Transaction.startedUtc
                transactionId = $Transaction.transactionId
                tweakName     = $record.tweakName
                entries       = $record.entries
            }
        } else {
            $tweaks.Remove($record.tweakId)
        }
    }

    $newIndex = [ordered]@{
        schemaVersion = $script:SchemaVersion
        updatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        machine       = $env:COMPUTERNAME
        tweaks        = $tweaks
    }
    Write-FOAtomicJson -Path (Join-Path $root 'applied.json') -Object $newIndex

    Write-FOLog -Level Info -Message "Transaction committed" -Data @{
        id        = $Transaction.transactionId
        operation = $Transaction.operation
        records   = $Transaction.records.Count
    }

    return $txPath
}

function Get-FOAppliedTweaks {
    <#
    .SYNOPSIS
        Returns the set of tweak ids currently recorded as applied.
    #>
    [CmdletBinding()]
    param()

    $index = Read-FOJournalIndex
    $result = @{}
    if ($index.PSObject.Properties.Name -contains 'tweaks' -and $index.tweaks) {
        foreach ($prop in $index.tweaks.PSObject.Properties) {
            $result[$prop.Name] = $prop.Value
        }
    }
    return $result
}

function Test-FOTweakApplied {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $TweakId)

    return (Get-FOAppliedTweaks).ContainsKey($TweakId)
}

function Get-FOTransactionHistory {
    <#
    .SYNOPSIS
        Lists every transaction ever committed, newest first.
    #>
    [CmdletBinding()]
    param([int] $Last = 50)

    $root = Get-FOJournalRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }

    Get-ChildItem -LiteralPath $root -Filter 'tx-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $Last |
        ForEach-Object {
            try {
                $tx = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                [pscustomobject]@{
                    TransactionId = $tx.transactionId
                    Operation     = $tx.operation
                    Description   = $tx.description
                    StartedUtc    = $tx.startedUtc
                    TweakCount    = @($tx.records).Count
                    Path          = $_.FullName
                }
            } catch { }
        }
}

function Get-FOTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $TransactionId)

    $path = Join-Path (Get-FOJournalRoot) "tx-$TransactionId.json"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "No such transaction: $TransactionId"
    }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

Export-ModuleMember -Function `
    Initialize-FOJournal, Read-FOJournalIndex, Restore-FOJournalIndex, `
    New-FOTransaction, Add-FOTransactionRecord, Save-FOTransaction, `
    Get-FOAppliedTweaks, Test-FOTweakApplied, Get-FOTransactionHistory, `
    Get-FOTransaction, Write-FOAtomicJson, Get-FOJournalRoot
