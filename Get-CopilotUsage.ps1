# This script will export two CSV files with data on Copilot licensing and usage.

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Reports.Read.All" -NoWelcome

$ReportFile = "./CopilotUsage.csv"

Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='D28',version='v2')" `
    -OutputFilePath $ReportFile

$Report = Import-Csv $ReportFile

$LastActivityColumn =
    ($Report[0].PSObject.Properties.Name |
        Where-Object {
            $_ -match "Last Activity Date"
        } |
        Select-Object -First 1)

$TotalUsers = $Report.Count

$ActiveUsers = @(
    $Report |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace(
                $_.$LastActivityColumn
            )
        }
).Count

$InactiveUsers = $TotalUsers - $ActiveUsers

$AdoptionPercent =
    [math]::Round(
        ($ActiveUsers / $TotalUsers) * 100,
        2
    )

Write-Host ""
Write-Host "Microsoft 365 Copilot Usage"
Write-Host "--------------------------"
Write-Host "Licensed Users : $TotalUsers"
Write-Host "Active Users   : $ActiveUsers"
Write-Host "Inactive Users : $InactiveUsers"
Write-Host "Adoption Rate  : $AdoptionPercent%"

$Report |
    Export-Csv `
        "./CopilotUsageReport.csv" `
        -NoTypeInformation

$Report |
    Where-Object {
        [string]::IsNullOrWhiteSpace(
            $_.$LastActivityColumn
        )
    } |
    Export-Csv `
        "./CopilotInactiveUsers.csv" `
        -NoTypeInformation

Write-Host ""
Write-Host "Created:"
Write-Host "  CopilotUsageReport.csv"
Write-Host "  CopilotInactiveUsers.csv"


Disconnect-MgGraph | Out-Null