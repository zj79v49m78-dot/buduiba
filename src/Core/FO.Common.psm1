<#
.SYNOPSIS
    Small shared helpers that must behave identically on Windows PowerShell 5.1
    and PowerShell 7.
.DESCRIPTION
    This module exists because of a specific class of bug that is invisible when
    developing on PowerShell 7 and fatal on Windows PowerShell 5.1 -- which is
    the version that ships with Windows and therefore the one this tool actually
    runs on.
#>

Set-StrictMode -Version Latest

function Test-FOHasProperty {
    <#
    .SYNOPSIS
        Returns whether an object has a named property.
    .DESCRIPTION
        The obvious way to write this is to take the Name member of the
        PSObject.Properties collection and test it with -contains.

        That relies on member enumeration -- projecting .Name across a
        PSMemberInfoCollection. PowerShell 7 permits it. Windows PowerShell 5.1
        under Set-StrictMode -Version Latest throws PropertyNotFoundStrict
        instead, because the collection itself has no .Name member.

        Enumerating explicitly works identically on both, and additionally
        tolerates a $null input rather than throwing -- which matters because
        several callers pass the result of Get-ItemProperty, and a registry key
        with no values yields nothing at all.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $InputObject) { return $false }

    $properties = $InputObject.PSObject.Properties
    if ($null -eq $properties) { return $false }

    foreach ($property in $properties) {
        if ($property.Name -eq $Name) { return $true }
    }

    return $false
}

function Get-FOPropertyValue {
    <#
    .SYNOPSIS
        Reads a property if present, otherwise returns a default.
    .DESCRIPTION
        Companion to Test-FOHasProperty for the very common
        "use this field if the definition supplied one" pattern.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [string] $Name,
        $Default = $null
    )

    if (Test-FOHasProperty -InputObject $InputObject -Name $Name) {
        return $InputObject.$Name
    }
    return $Default
}

function ConvertTo-FOArray {
    <#
    .SYNOPSIS
        Guarantees an array, even for null or a single item.
    .DESCRIPTION
        PowerShell unwraps single-element and empty collections on return, so a
        function that yields nothing gives the caller $null, and $null.Count
        throws under StrictMode. Callers use this (or @()) so .Count is always
        safe.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)] [AllowNull()] $InputObject)

    begin { $items = [System.Collections.ArrayList]::new() }
    process {
        if ($null -ne $InputObject) { $null = $items.Add($InputObject) }
    }
    end { return , $items.ToArray() }
}

Export-ModuleMember -Function Test-FOHasProperty, Get-FOPropertyValue, ConvertTo-FOArray
