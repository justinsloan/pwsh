# This script will list all licensed users that have not signed in within the last 30 days.

Connect-MgGraph `
    -Scopes "User.Read.All","AuditLog.Read.All","Organization.Read.All" `
    -NoWelcome

$DaysInactive = 30
$CutoffDate = (Get-Date).AddDays(-$DaysInactive)

$Results = foreach ($User in (
    Get-MgUser `
        -Filter "userType eq 'Member'" `
        -All `
        -Property Id,DisplayName,UserPrincipalName,AccountEnabled,AssignedLicenses,SignInActivity
)) {

    if (!$User.AccountEnabled) { continue }

    if (!$User.AssignedLicenses -or $User.AssignedLicenses.Count -eq 0) {
        continue
    }

    $LastSignIn = $null

    if ($User.SignInActivity.LastSignInDateTime) {
        $LastSignIn = [datetime]$User.SignInActivity.LastSignInDateTime
    }

    if ($LastSignIn -and $LastSignIn -ge $CutoffDate) {
        continue
    }

    try {
        $Licenses = (
            Get-MgUserLicenseDetail -UserId $User.Id |
            Select-Object -ExpandProperty SkuPartNumber -Unique |
            Sort-Object
        ) -join "; "
    }
    catch {
        $Licenses = "Unable to retrieve"
    }

    [PSCustomObject]@{
        DisplayName       = $User.DisplayName
        UserPrincipalName = $User.UserPrincipalName
        LastSignIn        = if ($LastSignIn) {
            $LastSignIn.ToString("yyyy-MM-dd")
        }
        else {
            "Never"
        }
        DaysInactive = if ($LastSignIn) {
            ((Get-Date) - $LastSignIn).Days
        }
        else {
            $null
        }
        Licenses = $Licenses
    }
}

$Results =
    $Results |
    Sort-Object DaysInactive -Descending

$Results |
    Export-Csv `
        -Path ".\InactiveLicensedUsers.csv" `
        -NoTypeInformation `
        -Encoding UTF8

$Results |
    Format-Table `
        DisplayName,
        UserPrincipalName,
        LastSignIn,
        DaysInactive,
        Licenses `
        -AutoSize `
        -Wrap

Write-Host ""
Write-Host "Found $($Results.Count) inactive licensed users." -ForegroundColor Green
Write-Host "CSV exported to InactiveLicensedUsers.csv" -ForegroundColor Green

Disconnect-MgGraph | Out-Null