#Requires -Version 7.0
#Requires -Modules ExchangeOnlineManagement

<#
.SYNOPSIS
    Exports a CSV of the mailboxes that are on Litigation Hold.

.DESCRIPTION
    Connects to Exchange Online and lists every mailbox where Litigation Hold is enabled, with
    the date the hold was placed and its duration. A duration of Unlimited means the hold has no
    end date.

    This script only reads. It never changes a hold.

    The list covers Litigation Hold only. A mailbox can also be held by an eDiscovery case or a
    Microsoft Purview retention policy, and those do not set LitigationHoldEnabled. They appear
    in the InPlaceHolds property instead. To check one mailbox, run:

        Get-Mailbox user@contoso.com | Format-List LitigationHoldEnabled, InPlaceHolds

    An ID that starts with UniH is an eDiscovery hold. An ID that starts with mbx or skp is a
    retention policy.

    Exchange does not place new mailboxes on Litigation Hold automatically, so running this
    now and then is a simple way to spot mailboxes that were missed.

.PARAMETER OutputPath
    Where to write the CSV. Defaults to ./LitigationHoldUsers.csv in the current folder.
    Display names can be changed by other people, so the script strips control characters from
    them and prefixes any cell that starts with = + - or @ (even after leading whitespace) with
    an apostrophe so spreadsheets treat it as text.

.PARAMETER UseDeviceCode
    Sign in with the device code flow: the script prints a code and a web address, and you finish
    signing in in a browser on any device. Use this on a headless server or over SSH.

.EXAMPLE
    ./Get-LitigationHolds.ps1

    Writes LitigationHoldUsers.csv to the current folder.

.EXAMPLE
    ./Get-LitigationHolds.ps1 -UseDeviceCode -OutputPath ./holds-2026-10.csv

    Signs in with a device code and writes the CSV to a file you choose.

.NOTES
    Author:  Justin Sloan
    License: MIT
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive tool: status output for a person at a terminal.')]
[CmdletBinding()]
param(
    [string]$OutputPath = './LitigationHoldUsers.csv',
    [switch]$UseDeviceCode
)

$ErrorActionPreference = 'Stop'

function ConvertTo-SafeText {
    # Display names come from the directory. Strip control and format characters so a hostile
    # value can't drive the terminal (ANSI escape sequences) or disguise the report layout.
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    [regex]::Replace($Text, '\p{C}', '')
}

function Protect-CsvCell {
    # Spreadsheets run cells that start with = + - or @ as formulas, and some importers trim
    # leading whitespace first, so look past any leading whitespace. Prefix an apostrophe so a
    # hostile value is shown as text instead of executed.
    param($Value)
    if ($Value -is [string] -and $Value -match '^\s*[=+\-@]') { "'" + $Value } else { $Value }
}

# --- Connect ---------------------------------------------------------------
$connected = $false
try {
    Write-Host 'Connecting to Exchange Online...'
    $connect = @{ ShowBanner = $false }
    if ($UseDeviceCode) { $connect.Device = $true }
    Connect-ExchangeOnline @connect
    $connected = $true
    Write-Host 'Connected.'
}
catch {
    Write-Host "Could not connect to Exchange Online: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# --- Query and export --------------------------------------------------------
try {
    Write-Host 'Querying mailboxes on Litigation Hold...'

    # -Filter makes Exchange Online do the filtering instead of returning every mailbox.
    $holds = @(Get-Mailbox -ResultSize Unlimited -Filter 'LitigationHoldEnabled -eq $true' |
        ForEach-Object {
            [pscustomobject][ordered]@{
                DisplayName            = Protect-CsvCell (ConvertTo-SafeText $_.DisplayName)
                PrimarySmtpAddress     = Protect-CsvCell (ConvertTo-SafeText ([string]$_.PrimarySmtpAddress))
                LitigationHoldDate     = $_.LitigationHoldDate
                LitigationHoldDuration = $_.LitigationHoldDuration
            }
        })

    $holds | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Host "Found $($holds.Count) mailbox(es) on Litigation Hold. Exported to $OutputPath" -ForegroundColor Green
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($connected) {
        Disconnect-ExchangeOnline -Confirm:$false
        Write-Host 'Disconnected from Exchange Online.'
    }
}
