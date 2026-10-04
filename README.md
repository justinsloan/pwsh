# pwsh
A collection of PowerShell scripts for systems administrators.

## Install

With PowerShell:

`Invoke-WebRequest -Uri https://raw.githubusercontent.com/justinsloan/pwsh/main/pwsh.ps1 -OutFile pwsh.ps1 | Import-Module ./pwsh.ps1`

## Scripts

### Get-AppConsentAudit.ps1

Read-only audit of which apps have been granted access to a Microsoft 365 tenant. It shows how
users are currently allowed to consent to apps, then lists every app holding delegated permissions
(and, optionally, application permissions), with a priority so the ones most worth reviewing sort
to the top. It never changes your tenant.

Requires PowerShell 7 and three Microsoft Graph PowerShell modules:

```powershell
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns -Scope CurrentUser
```

Examples:

```powershell
./Get-AppConsentAudit.ps1
./Get-AppConsentAudit.ps1 -ExcludeMicrosoftApps -OnlyRisky -OutputPath ./risky-apps.csv
./Get-AppConsentAudit.ps1 -IncludeApplicationPermissions -ResolveUsers -OutputPath ./audit.json
```

Run `Get-Help ./Get-AppConsentAudit.ps1 -Full` for every option. Try it in a test tenant first.

