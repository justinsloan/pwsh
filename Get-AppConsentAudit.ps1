#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns

<#
.SYNOPSIS
    Read-only audit of which apps have been granted access to a Microsoft 365 tenant.

.DESCRIPTION
    Shows how users are currently allowed to consent to apps, then lists every app that
    holds delegated permissions (access on behalf of a user) and, optionally, application
    permissions (access with the app's own identity). Each app gets a priority so the ones
    most worth reviewing sort to the top.

    This script only reads. It never changes your tenant. It requests two read-only
    Microsoft Graph permissions: Directory.Read.All and Policy.Read.All. Sign in with an
    account that can review enterprise application permissions (Microsoft documents at
    least Cloud Application Administrator for that task).

    Priority is a simple heuristic, not a verdict:
      High    risky application permission, or an unverified app with a tenant-wide risky grant
      Medium  risky delegated permission, or an unverified app with a user-level risky grant
      Low     everything else

    The default list of risky delegated scopes comes from the consent grant guidance on
    Microsoft Learn (anything that writes data, reads or sends mail, or impersonates the
    signed-in user). The default list of risky application roles is a conservative starting
    point. Override either list with -RiskyDelegatedScope and -RiskyApplicationRole.

.PARAMETER TenantId
    Tenant to connect to. Optional. Useful when your account belongs to several tenants.

.PARAMETER OutputPath
    Write the full report to this file. A .json extension writes JSON; anything else writes CSV.
    If omitted, no file is written. App names and other directory values can be set by other
    parties, so the script strips control characters from them, and in CSV output prefixes any
    cell that starts with = + - or @ with an apostrophe so spreadsheets treat it as text.

.PARAMETER IncludeApplicationPermissions
    Also report application permissions granted on Microsoft Graph, Exchange Online and
    SharePoint Online. Application permissions let an app act with no signed-in user.

.PARAMETER ResolveUsers
    List the user principal names of people who consented, not just a count. Makes one extra
    lookup per consenting user and needs the Microsoft.Graph.Users module.

.PARAMETER ExcludeMicrosoftApps
    Hide apps owned by Microsoft's own tenant. This removes most of the noise from Office,
    Teams, and other first-party apps.

.PARAMETER OnlyRisky
    Report only apps that hold at least one risky permission.

.PARAMETER RiskyDelegatedScope
    Wildcard patterns for delegated scopes to flag.

.PARAMETER RiskyApplicationRole
    Wildcard patterns for application roles to flag.

.PARAMETER PassThru
    Also return the report objects to the pipeline.

.EXAMPLE
    ./Get-AppConsentAudit.ps1

    Prints the consent policy and a summary, and lists the apps worth a closer look.

.EXAMPLE
    ./Get-AppConsentAudit.ps1 -ExcludeMicrosoftApps -OnlyRisky -OutputPath ./risky-apps.csv

    Third-party apps with risky permissions only, saved to a CSV.

.EXAMPLE
    ./Get-AppConsentAudit.ps1 -IncludeApplicationPermissions -ResolveUsers -OutputPath ./audit.json

    The most complete report, saved as JSON.

.NOTES
    Author:  Justin Sloan
    License: MIT
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive tool: colored status output for a person at a terminal.')]
[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$OutputPath,
    [switch]$IncludeApplicationPermissions,
    [switch]$ResolveUsers,
    [switch]$ExcludeMicrosoftApps,
    [switch]$OnlyRisky,
    [string[]]$RiskyDelegatedScope = @(
        '*.ReadWrite*', 'Mail.Read*', 'Mail.Send*', '*AccessAsUser*', 'user_impersonation'
    ),
    [string[]]$RiskyApplicationRole = @(
        '*.ReadWrite*', '*FullControl*', 'Mail.*', 'full_access_as_app', 'Files.Read*', 'Sites.Read*'
    ),
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

# Apps owned by this tenant are Microsoft's own first-party apps.
$MicrosoftTenantId = 'f8cdef31-a31e-4b4a-93e4-5f571e91255a'

# Resources whose application permissions are worth listing: well-known app IDs.
$ApplicationResources = [ordered]@{
    'Graph'      = '00000003-0000-0000-c000-000000000000'
    'Exchange'   = '00000002-0000-0ff1-ce00-000000000000'
    'SharePoint' = '00000003-0000-0ff1-ce00-000000000000'
}

if ($ResolveUsers) {
    try { Import-Module Microsoft.Graph.Users -ErrorAction Stop }
    catch { throw "-ResolveUsers needs the Microsoft.Graph.Users module. Install it with: Install-Module Microsoft.Graph.Users -Scope CurrentUser" }
}

function Get-RiskyMatch {
    # Returns the values that match any wildcard pattern.
    param([string[]]$Value, [string[]]$Pattern)
    foreach ($item in $Value) {
        foreach ($p in $Pattern) {
            if ($item -like $p) { $item; break }
        }
    }
}

function ConvertTo-SafeText {
    # Names, publishers and scopes come from the directory and can be set by other parties.
    # Strip control and format characters so a hostile value can't drive the terminal
    # (ANSI escape sequences) or disguise the report layout.
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    [regex]::Replace($Text, '\p{C}', '')
}

function Protect-CsvCell {
    # Spreadsheets run cells that start with = + - or @ as formulas. Prefix an apostrophe
    # so a hostile app name is shown as text instead of executed.
    param($Value)
    if ($Value -is [string] -and $Value -match '^[=+\-@]') { "'" + $Value } else { $Value }
}

$spCache   = @{}
$userCache = @{}
$records   = @{}

function Get-AppInfo([string]$ServicePrincipalId) {
    if (-not $spCache.ContainsKey($ServicePrincipalId)) {
        $spCache[$ServicePrincipalId] = Get-MgServicePrincipal -ServicePrincipalId $ServicePrincipalId `
            -Property Id, DisplayName, AppId, VerifiedPublisher, AppOwnerOrganizationId, AccountEnabled
    }
    $spCache[$ServicePrincipalId]
}

function Get-UserName([string]$UserId) {
    if (-not $userCache.ContainsKey($UserId)) {
        $name = try { (Get-MgUser -UserId $UserId -Property UserPrincipalName).UserPrincipalName }
                catch { $UserId }
        $userCache[$UserId] = ConvertTo-SafeText $name
    }
    $userCache[$UserId]
}

function Get-Record([string]$ServicePrincipalId) {
    if (-not $records.ContainsKey($ServicePrincipalId)) {
        $app = Get-AppInfo $ServicePrincipalId
        $records[$ServicePrincipalId] = [pscustomobject]@{
            App                   = ConvertTo-SafeText $app.DisplayName
            AppId                 = $app.AppId
            ServicePrincipalId    = $ServicePrincipalId
            Publisher             = ConvertTo-SafeText $app.VerifiedPublisher.DisplayName
            MicrosoftApp          = ($app.AppOwnerOrganizationId -eq $MicrosoftTenantId)
            Enabled               = $app.AccountEnabled
            TenantWideDelegated   = $false
            ConsentedUsers        = @()
            DelegatedScopes       = @()
            RiskyDelegatedScopes  = @()
            ApplicationRoles      = @()
            RiskyApplicationRoles = @()
            Priority              = 'Low'
        }
    }
    $records[$ServicePrincipalId]
}

# --- Connect ---------------------------------------------------------------
$connect = @{ Scopes = @('Directory.Read.All', 'Policy.Read.All'); NoWelcome = $true }
if ($TenantId) { $connect.TenantId = $TenantId }
Connect-MgGraph @connect

# --- 1. How are users allowed to consent today? ----------------------------
$policy   = Get-MgPolicyAuthorizationPolicy
$assigned = @($policy.DefaultUserRolePermissions.PermissionGrantPoliciesAssigned)

Write-Host "`nUser consent policy:" -ForegroundColor Cyan
if ($assigned.Count -eq 0) {
    Write-Host '  User consent is disabled. Users must request admin approval.' -ForegroundColor Green
}
foreach ($policyId in $assigned) {
    $id = ConvertTo-SafeText $policyId
    switch -Wildcard ($id) {
        '*user-default-legacy' { Write-Host "  $id  <-- users can consent to ANY app" -ForegroundColor Yellow }
        '*user-default-low'    { Write-Host "  $id  <-- verified publishers, low-impact permissions only" -ForegroundColor Green }
        default                { Write-Host "  $id" }
    }
}

# --- 2. Delegated permissions (access on behalf of a user) ------------------
Write-Progress -Activity 'App consent audit' -Status 'Reading delegated permission grants'
foreach ($grant in (Get-MgOauth2PermissionGrant -All)) {
    $record = Get-Record $grant.ClientId
    $scopes = @($grant.Scope -split ' ' | ForEach-Object { ConvertTo-SafeText $_ } | Where-Object { $_ })
    $record.DelegatedScopes = @(($record.DelegatedScopes + $scopes) | Sort-Object -Unique)

    if ($grant.ConsentType -eq 'AllPrincipals') {
        $record.TenantWideDelegated = $true
    }
    elseif ($grant.PrincipalId) {
        $record.ConsentedUsers = @(($record.ConsentedUsers + $grant.PrincipalId) | Sort-Object -Unique)
    }
}

# --- 3. Application permissions (access with the app's own identity) --------
if ($IncludeApplicationPermissions) {
    foreach ($resourceName in $ApplicationResources.Keys) {
        Write-Progress -Activity 'App consent audit' -Status "Reading application permissions on $resourceName"
        $resource = Get-MgServicePrincipal -Filter "appId eq '$($ApplicationResources[$resourceName])'" `
            -Property Id, DisplayName, AppRoles
        if (-not $resource) { continue }

        $roleNames = @{}
        foreach ($role in $resource.AppRoles) { $roleNames[$role.Id] = $role.Value }

        foreach ($assignment in (Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $resource.Id -All)) {
            if ($assignment.PrincipalType -ne 'ServicePrincipal') { continue }

            $record   = Get-Record $assignment.PrincipalId
            $roleName = $roleNames[$assignment.AppRoleId]
            if (-not $roleName) { $roleName = [string]$assignment.AppRoleId }
            $roleName = ConvertTo-SafeText $roleName

            $record.ApplicationRoles = @($record.ApplicationRoles + "$resourceName/$roleName")
            if (Get-RiskyMatch -Value $roleName -Pattern $RiskyApplicationRole) {
                $record.RiskyApplicationRoles = @($record.RiskyApplicationRoles + "$resourceName/$roleName")
            }
        }
    }
}
Write-Progress -Activity 'App consent audit' -Completed

# --- 4. Score each app, then build the report -------------------------------
foreach ($record in $records.Values) {
    $record.RiskyDelegatedScopes = @(Get-RiskyMatch -Value $record.DelegatedScopes -Pattern $RiskyDelegatedScope)

    $score = 0
    if ($record.RiskyApplicationRoles.Count) { $score += 3 }
    if ($record.RiskyDelegatedScopes.Count)  { $score += $(if ($record.TenantWideDelegated) { 2 } else { 1 }) }
    if (-not $record.Publisher -and -not $record.MicrosoftApp) { $score += 1 }

    $record.Priority = if ($score -ge 3) { 'High' } elseif ($score -eq 2) { 'Medium' } else { 'Low' }
}

$report = foreach ($record in $records.Values) {
    if ($ExcludeMicrosoftApps -and $record.MicrosoftApp) { continue }
    if ($OnlyRisky -and -not ($record.RiskyDelegatedScopes.Count -or $record.RiskyApplicationRoles.Count)) { continue }

    [pscustomobject]@{
        Priority              = $record.Priority
        App                   = $record.App
        ServicePrincipalId    = $record.ServicePrincipalId
        AppId                 = $record.AppId
        Publisher             = $record.Publisher
        MicrosoftApp          = $record.MicrosoftApp
        Enabled               = $record.Enabled
        TenantWideDelegated   = $record.TenantWideDelegated
        ConsentedUserCount    = $record.ConsentedUsers.Count
        ConsentedUsers        = $(if ($ResolveUsers) { ($record.ConsentedUsers | ForEach-Object { Get-UserName $_ }) -join '; ' } else { '' })
        RiskyDelegatedScopes  = $record.RiskyDelegatedScopes -join ' '
        DelegatedScopes       = $record.DelegatedScopes -join ' '
        RiskyApplicationRoles = $record.RiskyApplicationRoles -join ' '
        ApplicationRoles      = $record.ApplicationRoles -join ' '
    }
}

$report = @($report | Sort-Object `
    @{ Expression = { switch ($_.Priority) { 'High' { 0 } 'Medium' { 1 } default { 2 } } } }, `
    App)

# --- 5. Output --------------------------------------------------------------
if ($OutputPath) {
    if ([System.IO.Path]::GetExtension($OutputPath) -eq '.json') {
        $report | ConvertTo-Json -Depth 3 | Set-Content -Path $OutputPath
    }
    else {
        $report | ForEach-Object {
            $row = [ordered]@{}
            foreach ($property in $_.PSObject.Properties) { $row[$property.Name] = Protect-CsvCell $property.Value }
            [pscustomobject]$row
        } | Export-Csv -Path $OutputPath -NoTypeInformation
    }
    Write-Host "`nFull report saved to $OutputPath" -ForegroundColor Cyan
}

$high   = @($report | Where-Object Priority -eq 'High').Count
$medium = @($report | Where-Object Priority -eq 'Medium').Count
$low    = @($report | Where-Object Priority -eq 'Low').Count
Write-Host "`n$($report.Count) apps reported: $high high, $medium medium, $low low priority." -ForegroundColor Cyan

if ($high + $medium -gt 0) {
    Write-Host "`nReview these first:" -ForegroundColor Cyan
    $report | Where-Object Priority -ne 'Low' |
        Format-List Priority, App, ServicePrincipalId, Publisher, TenantWideDelegated,
            ConsentedUserCount, RiskyDelegatedScopes, RiskyApplicationRoles |
        Out-Host
}

Disconnect-MgGraph | Out-Null

if ($PassThru) { $report }
