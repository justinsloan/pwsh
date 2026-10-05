# This script will find all groups in the tenant with no users, and show whether each one
# still has other members (devices, contacts, service principals or other groups).

Connect-MgGraph -Scopes "Group.Read.All" -NoWelcome

Write-Host "Running... Please wait. This may take a while."

$Groups = Get-MgGroup -All

$Results = foreach ($Group in $Groups) {
    try {
        $UserCount = [int](Get-MgGroupMemberCountAsUser -GroupId $Group.Id -ConsistencyLevel eventual)

        if ($UserCount -eq 0) {
            $MemberCount = [int](Get-MgGroupMemberCount -GroupId $Group.Id -ConsistencyLevel eventual)

            [PSCustomObject]@{
                DisplayName = $Group.DisplayName
                GroupId     = $Group.Id
                UserCount   = $UserCount
                MemberCount = $MemberCount
                HasMembers  = $MemberCount -gt 0
            }
        }
    }
    catch {
        Write-Warning "Could not check '$($Group.DisplayName)': $($_.Exception.Message)"
    }
}

$Results | Export-Csv "./EmptyEntraGroups.csv" -NoTypeInformation
$Results
