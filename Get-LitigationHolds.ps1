# This script will export a CSV of users currently on ligitation hold in the tenant.

# Connect to Exchange Online
try {
    Write-Host "Connecting to Exchange Online..."
    Connect-ExchangeOnline -ErrorAction Stop
    Write-Host "Successfully connected to Exchange Online."
} catch {
    Write-Host "Failed to connect to Exchange Online. Please check your credentials." -ForegroundColor Red
    exit
}

try {
    Write-Host "Attempting to query ligitgation holds..."

    Get-Mailbox -ResultSize Unlimited |
    Where-Object {$_.LitigationHoldEnabled -eq $true} |
    Select DisplayName,PrimarySmtpAddress,LitigationHoldDate,LitigationHoldDuration |
    Export-Csv .\LitigationHoldUsers.csv -NoTypeInformation

    Write-Host "Success. Exported to LitigationHoldUsers.csv"
}
catch {
    Write-Host "❌ Error: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false
    Write-Host "Disconnected from Exchange Online."
}