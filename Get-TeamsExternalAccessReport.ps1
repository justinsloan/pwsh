#Requires -Modules MicrosoftTeams
<#
.SYNOPSIS
    Checks who outside your organization can chat with your users in Microsoft Teams, and
    suggests what to tighten. Read-only.

.DESCRIPTION
    Connects to Microsoft Teams PowerShell and reads the external access settings: which other
    Microsoft 365 organizations can chat with your users, whether people with personal Teams
    accounts can, whether organizations with only trial licenses are blocked, any blocked
    external users, and the external access policies that decide which of your users the
    settings apply to. It describes each setting in plain words, prints a table with
    suggestions, and saves the results to a CSV file. It changes nothing in the tenant.

    Works in PowerShell 7 on Windows, Linux and macOS.

.PARAMETER UseDeviceCode
    Sign in with a code on another device. Use this on a machine without a browser.

.PARAMETER OutputPath
    Where to save the CSV. Defaults to TeamsExternalAccess.csv in the current folder.

.EXAMPLE
    ./Get-TeamsExternalAccessReport.ps1 -UseDeviceCode

.NOTES
    Needs the MicrosoftTeams module and an account that can read Teams settings, such as a
    Teams Administrator.
#>
[CmdletBinding()]
param(
    [switch]$UseDeviceCode,
    [string]$OutputPath = './TeamsExternalAccess.csv'
)

$findings = [System.Collections.Generic.List[object]]::new()

function Add-Finding {
    # One row of the report: a setting, its value in plain words, and what to consider changing.
    param([string]$Setting, [string]$Value, [string]$Advice = '')
    $findings.Add([pscustomobject]@{ Setting = $Setting; Value = $Value; Advice = $Advice })
}

function Get-DomainList {
    # Returns the domain names in an allowed or blocked list, whichever form the module uses:
    # objects with a Domain property, an allow list with an AllowedDomain property, or text
    # such as "Domain=contoso.com".
    param($Value)
    @(foreach ($item in @($Value | Where-Object { $_ })) {
        if ($item.PSObject.Properties['AllowedDomain']) { Get-DomainList -Value $item.AllowedDomain; continue }
        if ($item.PSObject.Properties['Domain'] -and $item.Domain) { "$($item.Domain)"; continue }
        $text = "$item"
        $matched = [regex]::Matches($text, 'Domain=([^\s,;{}]+)')
        if ($matched.Count -gt 0) { $matched | ForEach-Object { $_.Groups[1].Value } }
        elseif ($text -and $text -notmatch 'AllowAllKnownDomains') { $text }
    })
}

function Test-AllowAllDomain {
    # True when the allowed list is "allow all known domains", the Teams default.
    param($Value)
    foreach ($item in @($Value | Where-Object { $null -ne $_ })) {
        if ($item.GetType().Name -eq 'AllowAllKnownDomains' -or "$item" -match 'AllowAllKnownDomains') { return $true }
    }
    $false
}

function Get-OnOff {
    # Settings come back as True or False; anything else is reported as on, the Teams default.
    param($Value)
    if ("$Value" -eq 'False') { 'off' } else { 'on' }
}

$connect = @{ ErrorAction = 'Stop' }
if ($UseDeviceCode) { $connect.UseDeviceAuthentication = $true }
elseif (($IsLinux -or $IsMacOS) -and (Get-Command Connect-MicrosoftTeams).Parameters.ContainsKey('DisableWAM')) {
    # The module's default sign-in goes through Web Account Manager, which exists only on
    # Windows. Elsewhere it fails looking for kernel32.dll, so ask for the browser sign-in.
    $connect.DisableWAM = $true
}
Connect-MicrosoftTeams @connect | Out-Null

try {
    $federation = Get-CsTenantFederationConfiguration -ErrorAction Stop

    # Other Microsoft 365 organizations. AllowFederatedUsers is the master switch.
    $allowed = @(Get-DomainList -Value $federation.AllowedDomains)
    $blocked = @(Get-DomainList -Value $federation.BlockedDomains)
    $setting = 'Other Microsoft 365 organizations'
    if ("$($federation.AllowFederatedUsers)" -eq 'False') {
        Add-Finding $setting 'Off for everyone'
    }
    elseif ($null -eq $federation.AllowedDomains) {
        Add-Finding $setting 'Unknown' -Advice "Couldn't read the allowed domains. Check Users > External access in the Teams admin center."
    }
    elseif (Test-AllowAllDomain -Value $federation.AllowedDomains) {
        $value = 'Any organization can chat with your users'
        if ($blocked.Count -gt 0) { $value += ", except $($blocked.Count) blocked domain(s): $($blocked -join ', ')" }
        Add-Finding $setting $value -Advice 'Allow only the organizations you work with.'
    }
    elseif ($allowed.Count -eq 0) {
        Add-Finding $setting 'None, unless a custom policy allows some'
    }
    else {
        Add-Finding $setting "Only $($allowed.Count) listed domain(s): $($allowed -join ', ')"
    }

    # People with personal (unmanaged) Teams accounts.
    $setting = 'Personal Teams accounts'
    if ("$($federation.AllowTeamsConsumer)" -eq 'False') {
        Add-Finding $setting 'Off'
    }
    elseif ("$($federation.AllowTeamsConsumerInbound)" -eq 'False') {
        Add-Finding $setting 'On, but only your users can start a chat'
    }
    else {
        Add-Finding $setting 'On, and they can start chats with your users' -Advice 'Turn this off, or at least stop personal accounts from starting chats.'
    }

    # Organizations that have only trial licenses. Blocked is the default.
    $setting = 'Organizations with only trial licenses'
    switch ("$($federation.ExternalAccessWithTrialTenants)") {
        'Blocked' { Add-Finding $setting 'Blocked' }
        'Allowed' { Add-Finding $setting 'Allowed' -Advice 'Set this to Blocked unless you work with an organization that has only trial licenses.' }
        default   { Add-Finding $setting 'Not reported' -Advice 'Update the MicrosoftTeams module to see this setting.' }
    }

    # Individual external people the organization has blocked.
    try {
        $access = Get-CsTeamsExternalAccessConfiguration -ErrorAction Stop
        $users = @($access.BlockedUsers | Where-Object { $_ })
        if ("$($access.BlockExternalAccessUserAccess)" -eq 'True') { Add-Finding 'Blocked external users' "On, $($users.Count) blocked" }
        else { Add-Finding 'Blocked external users' 'Off' }
    }
    catch {
        Write-Warning "Couldn't read the blocked users list: $($_.Exception.Message)"
    }

    # External access policies decide which of your users the settings above apply to. Global
    # covers everyone who doesn't have a custom policy.
    foreach ($policy in @(Get-CsExternalAccessPolicy -ErrorAction Stop)) {
        $name = "$($policy.Identity)" -replace '^Tag:', ''
        if ($name -eq 'Global') { $name = 'Global (everyone without a custom policy)' }
        $parts = @("other organizations $(Get-OnOff $policy.EnableFederationAccess)")
        $domains = "$($policy.CommunicationWithExternalOrgs)"
        if ($domains -and $domains -ne 'OrganizationDefault') { $parts += "domains: $domains" }
        $parts += "personal accounts $(Get-OnOff $policy.EnableTeamsConsumerAccess)"
        $parts += "personal accounts can start chats $(Get-OnOff $policy.EnableTeamsConsumerInbound)"
        $advice = ''
        if ($domains -eq 'AllowAllExternalDomains') { $advice = 'Its users can chat with any organization, whatever the organization setting says.' }
        Add-Finding "Policy: $name" ($parts -join '; ') -Advice $advice
    }
}
finally {
    Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue | Out-Null
}

$findings | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8
$findings | Format-Table Setting, Value, Advice -Wrap | Out-String -Width 200 | Write-Host

$todo = @($findings | Where-Object Advice)
if ($todo.Count -gt 0) {
    Write-Host "$($todo.Count) setting(s) worth a look. The same table is saved in $OutputPath"
}
else {
    Write-Host "Nothing to tighten in these settings. The same table is saved in $OutputPath"
}
