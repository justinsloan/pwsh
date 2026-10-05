# This script will list all licensed users that have not signed in within the last 30 days.

Connect-MgGraph `
    -Scopes "User.Read.All","AuditLog.Read.All" `
    -NoWelcome

Write-Host "Running... Please wait. This may take a while."

$DaysInactive = 30
$CutoffDate = (Get-Date).AddDays(-$DaysInactive)

try {
    $Users = Get-MgUser `
        -Filter "userType eq 'Member'" `
        -All `
        -Property Id,DisplayName,UserPrincipalName,AccountEnabled,AssignedLicenses,CreatedDateTime,SignInActivity
}
catch {
    Write-Warning "Could not read users: $($_.Exception.Message)"
    Write-Warning "Sign-in activity needs Microsoft Entra ID P1 or P2 and the AuditLog.Read.All permission."
    return
}

$Results = foreach ($User in $Users) {

    if (!$User.AccountEnabled) { continue }

    if (!$User.AssignedLicenses -or $User.AssignedLicenses.Count -eq 0) {
        continue
    }

    # Skip accounts created inside the window. They may simply not have signed in yet.
    if ($User.CreatedDateTime -and [datetime]$User.CreatedDateTime -ge $CutoffDate) { continue }

    # Last successful sign-in, interactive or not. Failed attempts do not count.
    $LastSignIn = $null

    if ($User.SignInActivity.LastSuccessfulSignInDateTime) {
        $LastSignIn = [datetime]$User.SignInActivity.LastSuccessfulSignInDateTime
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
            "None recorded"
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

if (-not $Results) {
    Write-Host "No inactive licensed users were found."
    return
}

# Accounts with no recorded sign-in are the most inactive, so list them first.
$Results =
    $Results |
    Sort-Object @{ Expression = { if ($null -eq $_.DaysInactive) { [int]::MaxValue } else { $_.DaysInactive } }; Descending = $true }

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
Write-Host "Found $(@($Results).Count) inactive licensed users." -ForegroundColor Green
Write-Host "CSV exported to InactiveLicensedUsers.csv" -ForegroundColor Green

Disconnect-MgGraph | Out-Null
