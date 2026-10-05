#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Finds Microsoft 365 Copilot licenses that are not being used.

.DESCRIPTION
    Downloads the Microsoft 365 Copilot usage report for licensed users from Microsoft Graph,
    prints how many people used Copilot in the report period, and writes two CSV files:

      CopilotUsage.csv          the full report, one row per licensed user
      CopilotInactiveUsers.csv  users with no Copilot activity in the report period

    A person counts as active when their Last Activity Date falls inside the report period.
    The comparison matters: Microsoft documents that date as the most recent activity on record,
    regardless of the report period you choose, so a date by itself does not mean recent use.

    This script only reads. It requests the Reports.Read.All permission. The signed-in account
    also needs an admin role that can read usage reports, such as Reports Reader.

    The report only covers users who have a Microsoft 365 Copilot license. By default Microsoft
    hides user names in usage reports, so the CSV may contain scrambled IDs instead of names. A
    Global Administrator can show real names under Settings, Org Settings, Services, Reports in
    the Microsoft 365 admin center (clear "Conceal user, group, and site names in all reports").
    The script warns you when it sees hidden names.

.PARAMETER Period
    Report period. D7, D28, D90 or D180. Defaults to D28.

.PARAMETER OutputFolder
    Folder for the two CSV files. Defaults to the current folder.
    User names can be changed by other people, so in the inactive-users CSV the script strips
    control characters from text and prefixes any cell that starts with = + - or @ (even after
    leading whitespace) with an apostrophe so spreadsheets treat it as text. CopilotUsage.csv is
    the report exactly as Microsoft returns it.

.PARAMETER TenantId
    Tenant to connect to. Optional. Useful when your account belongs to several tenants.

.PARAMETER UseDeviceCode
    Sign in with the device code flow: the script prints a code and a web address, and you finish
    signing in in a browser on any device. Use this on a headless server or over SSH.

.EXAMPLE
    ./Get-CopilotUsage.ps1

    Reports on the last 28 days and writes both CSV files to the current folder.

.EXAMPLE
    ./Get-CopilotUsage.ps1 -Period D90 -OutputFolder ~/reports -UseDeviceCode

    Reports on the last 90 days, signs in with a device code, and saves the files in ~/reports.

.NOTES
    Author:  Justin Sloan
    License: MIT
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive tool: status output for a person at a terminal.')]
[CmdletBinding()]
param(
    [ValidateSet('D7', 'D28', 'D90', 'D180')]
    [string]$Period = 'D28',
    [string]$OutputFolder = '.',
    [string]$TenantId,
    [switch]$UseDeviceCode
)

$ErrorActionPreference = 'Stop'

function ConvertTo-SafeText {
    # User names come from the directory. Strip control and format characters so a hostile value
    # can't drive the terminal (ANSI escape sequences) or disguise the report layout.
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

if (-not (Test-Path -LiteralPath $OutputFolder -PathType Container)) {
    Write-Host "Output folder not found: $OutputFolder" -ForegroundColor Red
    exit 1
}
$reportFile   = Join-Path $OutputFolder 'CopilotUsage.csv'
$inactiveFile = Join-Path $OutputFolder 'CopilotInactiveUsers.csv'
$days         = [int]$Period.Substring(1)

# --- Connect and download ----------------------------------------------------
$connected = $false
try {
    $connect = @{ Scopes = @('Reports.Read.All'); NoWelcome = $true }
    if ($TenantId) { $connect.TenantId = $TenantId }
    if ($UseDeviceCode) { $connect.UseDeviceCode = $true }
    Connect-MgGraph @connect
    $connected = $true

    $base = 'https://graph.microsoft.com/v1.0/copilot/reports'
    $uri  = "$base/getMicrosoft365CopilotUsageUserDetail(period='$Period',version='v2')"
    Invoke-MgGraphRequest -Method GET -Uri $uri -OutputFilePath $reportFile
}
catch {
    Write-Host "Could not download the Copilot usage report: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($connected) { Disconnect-MgGraph | Out-Null }
}

# --- Work out who is active --------------------------------------------------
$report = @(Import-Csv -LiteralPath $reportFile)
if ($report.Count -eq 0) {
    Write-Host 'No licensed users in the report.' -ForegroundColor Yellow
    return
}

$lastColumn = 'Last Activity Date'
if ($lastColumn -notin $report[0].PSObject.Properties.Name) {
    Write-Host "The report has no '$lastColumn' column, so activity can't be checked. Saved the report to $reportFile" -ForegroundColor Red
    exit 1
}

# Hidden names come back as 32-character hex IDs.
if ($report[0].'User Principal Name' -match '^[0-9A-Fa-f]{32}$') {
    Write-Host 'User names look hidden in this report. See the help (Get-Help ./Get-CopilotUsage.ps1) to show them.' -ForegroundColor Yellow
}

$cutoff = (Get-Date).Date.AddDays(-$days)
$inactive = @($report | Where-Object {
    $text = $_.$lastColumn
    $date = [datetime]::MinValue
    -not [datetime]::TryParseExact($text, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, 'None', [ref]$date) -or $date -lt $cutoff
})

$total  = $report.Count
$active = $total - $inactive.Count
$rate   = $active / $total

Write-Host ''
Write-Host "Microsoft 365 Copilot usage, last $days days" -ForegroundColor Cyan
Write-Host "  Licensed users : $total"
Write-Host "  Active users   : $active"
Write-Host "  Inactive users : $($inactive.Count)"
Write-Host ("  Adoption rate  : {0:P0}" -f $rate)

# --- Export --------------------------------------------------------------------
$safeInactive = foreach ($row in $inactive) {
    $copy = [ordered]@{}
    foreach ($property in $row.PSObject.Properties) {
        $copy[$property.Name] = Protect-CsvCell (ConvertTo-SafeText ([string]$property.Value))
    }
    [pscustomobject]$copy
}
$safeInactive | Export-Csv -LiteralPath $inactiveFile -NoTypeInformation

Write-Host ''
Write-Host 'Created:'
Write-Host "  $reportFile"
Write-Host "  $inactiveFile"
