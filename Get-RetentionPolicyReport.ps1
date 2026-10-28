#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    Lists every Microsoft Purview retention policy in a Microsoft 365 tenant: what each one
    covers, what it does, and whether anything covers Copilot. Read-only.

.DESCRIPTION
    Connects to Security & Compliance PowerShell and reads both families of retention policy:
    the older ones (Get-RetentionCompliancePolicy, which also returns retention label policies)
    and the newer app policies (Get-AppRetentionCompliancePolicy, used for Teams chats, Copilot
    and other AI apps, and Viva Engage). It reads each policy's rule, prints a summary, and saves
    the details to a CSV file. It changes nothing in the tenant.

    Security & Compliance PowerShell works only on Windows. Microsoft doesn't offer it in
    PowerShell 7 on Linux or macOS.

.PARAMETER UserPrincipalName
    The account to sign in with, for example admin@contoso.com. Optional.

.PARAMETER OutputPath
    Where to save the CSV. Defaults to RetentionPolicies.csv in the current folder.

.EXAMPLE
    .\Get-RetentionPolicyReport.ps1 -UserPrincipalName admin@contoso.com

.NOTES
    Needs the ExchangeOnlineManagement module (3.2.0 or later) and an account with the
    View-Only Retention Management role. The Global Reader role group includes it.
#>
[CmdletBinding()]
param(
    [string]$UserPrincipalName,
    [string]$OutputPath = './RetentionPolicies.csv'
)

# Retention actions as a rule stores them, in plain words.
$actionText = @{
    Keep          = 'Retain'
    KeepAndDelete = 'Retain, then delete'
    Delete        = 'Delete'
}

# Location property names, minus "Location", in the words the Purview portal uses.
$locationText = @{
    Exchange      = 'Exchange mailboxes'
    SharePoint    = 'SharePoint sites'
    OneDrive      = 'OneDrive accounts'
    ModernGroup   = 'Microsoft 365 Groups'
    PublicFolder  = 'Exchange public folders'
    Skype         = 'Skype for Business'
    TeamsChat     = 'Teams chats'
    TeamsChannel  = 'Teams channel messages'
    AdaptiveScope = 'Adaptive scopes'
}

function Format-Duration {
    # 2555 becomes "7 years", 30 becomes "30 days".
    param([int]$Days)
    if ($Days -ge 365 -and $Days % 365 -eq 0) {
        $years = $Days / 365
        if ($years -eq 1) { return '1 year' }
        return "$years years"
    }
    if ($Days -eq 1) { return '1 day' }
    return "$Days days"
}

function Get-LocationText {
    # Lists what a policy covers, for example "Exchange: All; OneDrive: 3 selected; Apps: User:M365Copilot".
    param($Policy)
    $parts = @(foreach ($property in $Policy.PSObject.Properties) {
        if ($property.Name -notlike '*Location') { continue }
        $values = @($property.Value | Where-Object { $_ })
        if ($values.Count -eq 0) { continue }
        $names = @(foreach ($value in $values) {
            if ($value.PSObject.Properties['Name'] -and $value.Name) { $value.Name } else { "$value" }
        })
        $label = $property.Name -replace 'Location$', ''
        if ($locationText[$label]) { $label = $locationText[$label] }
        if ($names -contains 'All') { "${label}: All" } else { "${label}: $($names.Count) selected" }
    })
    $apps = @($Policy.Applications | Where-Object { $_ })
    if ($apps.Count -gt 0) { $parts += "Apps: $($apps -join ', ')" }
    $parts -join '; '
}

function Get-RuleText {
    # Describes what one rule does, for example "Retain for 7 years, then delete (counted from creation)".
    param($Rule)
    if ($Rule.PublishComplianceTag) { return "Publishes retention label: $($Rule.PublishComplianceTag)" }
    if ($Rule.ApplyComplianceTag) { return "Auto-applies retention label: $($Rule.ApplyComplianceTag)" }

    $action = "$($Rule.RetentionComplianceAction)"
    $duration = "$($Rule.RetentionDuration)"
    if ($duration -match '^\d+$') {
        $period = Format-Duration -Days ([int]$duration)
        $text = switch ($action) {
            'Keep'          { "Retain for $period" }
            'KeepAndDelete' { "Retain for $period, then delete" }
            'Delete'        { "Delete after $period" }
            default         { "$action, $period" }
        }
    }
    elseif ($action -eq 'Keep' -and ($duration -eq 'Unlimited' -or -not $duration)) {
        $text = 'Retain forever'
    }
    else {
        $text = (@($actionText[$action], $action, 'Unknown action') | Where-Object { $_ })[0]
        if ($duration) { $text += ", $duration" }
    }

    switch ("$($Rule.ExpirationDateOption)") {
        'CreationAgeInDays'     { $text += ' (counted from creation)' }
        'ModificationAgeInDays' { $text += ' (counted from last change)' }
    }
    $text
}

function ConvertTo-ReportRow {
    # Turns one policy and its rules into one row of the report.
    param($Policy, $Rules, [switch]$AppPolicy)
    $rules = @($Rules | Where-Object { $_ })
    $apps = @($Policy.Applications | Where-Object { $_ })
    $olderTeamsChat = -not $AppPolicy -and @($Policy.TeamsChatLocation | Where-Object { $_ }).Count -gt 0

    $type = 'Retention policy'
    if (@($rules | Where-Object { $_.PublishComplianceTag }).Count -gt 0) { $type = 'Retention label policy (published)' }
    elseif (@($rules | Where-Object { $_.ApplyComplianceTag }).Count -gt 0) { $type = 'Retention label policy (auto-apply)' }

    $notes = @()
    if ("$($Policy.Enabled)" -eq 'False') { $notes += 'Turned off.' }
    if ($Policy.Mode -and "$($Policy.Mode)" -ne 'Enforce') { $notes += "Mode is $($Policy.Mode), not Enforce." }
    if ("$($Policy.RestrictiveRetention)" -eq 'True') { $notes += "Preservation Lock is on, so it can't be turned off or shortened." }
    if ($olderTeamsChat) {
        $notes += "Older Teams chats policy. Microsoft treats these as Teams-only, so don't count on it for Copilot."
    }

    $does = 'No rule found'
    if ($rules.Count -gt 0) { $does = (@($rules | ForEach-Object { Get-RuleText -Rule $_ }) -join ' | ') }

    [pscustomobject]@{
        Name           = $Policy.Name
        Type           = $type
        Enabled        = $Policy.Enabled
        Status         = $Policy.DistributionStatus
        Covers         = Get-LocationText -Policy $Policy
        Does           = $does
        CoversCopilot  = @($apps | Where-Object { $_ -match 'Copilot' }).Count -gt 0
        OlderTeamsChat = $olderTeamsChat
        Notes          = $notes -join ' '
    }
}

if ($IsLinux -or $IsMacOS) {
    Write-Warning "Microsoft doesn't offer Security & Compliance PowerShell on Linux or macOS, so the connection will probably fail. Run this on Windows, or check the policies in the Purview portal."
}

$connect = @{ ShowBanner = $false; ErrorAction = 'Stop' }
if ($UserPrincipalName) { $connect.UserPrincipalName = $UserPrincipalName }
Connect-IPPSSession @connect

try {
    $report = [System.Collections.Generic.List[object]]::new()

    # Older retention policies and retention label policies. Locations are accurate only with
    # -DistributionDetail, which Microsoft documents one policy at a time.
    foreach ($summary in @(Get-RetentionCompliancePolicy -ErrorAction Stop)) {
        try {
            $policy = Get-RetentionCompliancePolicy -Identity $summary.Name -DistributionDetail -ErrorAction Stop
            $rules = Get-RetentionComplianceRule -Policy $summary.Name -ErrorAction Stop
            $report.Add((ConvertTo-ReportRow -Policy $policy -Rules $rules))
        }
        catch {
            Write-Warning "Couldn't read the policy '$($summary.Name)': $($_.Exception.Message)"
        }
    }

    # Newer app policies: Teams chats, Copilot and AI apps, Viva Engage, Teams call logs.
    try {
        $appPolicies = @(Get-AppRetentionCompliancePolicy -ErrorAction Stop)
    }
    catch {
        Write-Warning "Couldn't list app retention policies: $($_.Exception.Message)"
        $appPolicies = @()
    }
    foreach ($summary in $appPolicies) {
        if ($report.Name -contains $summary.Name) { continue }
        try {
            $policy = Get-AppRetentionCompliancePolicy -Identity $summary.Name -DistributionDetail -ErrorAction Stop
            $rules = Get-AppRetentionComplianceRule -Policy $summary.Name -ErrorAction Stop
            $report.Add((ConvertTo-ReportRow -Policy $policy -Rules $rules -AppPolicy))
        }
        catch {
            Write-Warning "Couldn't read the policy '$($summary.Name)': $($_.Exception.Message)"
        }
    }
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

if ($report.Count -eq 0) {
    Write-Host 'No retention policies were found in this tenant.'
    return
}

$report | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8
$report | Format-Table Name, Type, Status, Does -Wrap | Out-String -Width 200 | Write-Host
Write-Host "Found $($report.Count) policies. Full details, including what each one covers, are in $OutputPath"

# Last, say whether anything covers Copilot. Older Teams chats policies don't count.
$copilot = @($report | Where-Object CoversCopilot)
$olderTeams = @($report | Where-Object OlderTeamsChat)
if ($copilot.Count -gt 0) {
    Write-Host "Copilot prompts and responses are covered by: $($copilot.Name -join ', ')"
}
elseif ($olderTeams.Count -gt 0) {
    Write-Host "No policy covers Copilot prompts and responses. Older Teams chats policies ($($olderTeams.Name -join ', ')) don't count, because Microsoft treats them as Teams-only."
}
else {
    Write-Host 'No retention policy covers Copilot prompts and responses.'
}
