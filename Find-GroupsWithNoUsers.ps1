# This script will find all groups in the tenant with no users.

Connect-MgGraph -Scopes "Group.Read.All" -NoWelcome

$EmptyGroups = Get-MgGroup -All

$Results = foreach ($Group in $EmptyGroups) {
    $Members = Get-MgGroupMember -GroupId $Group.Id

    if ($Members.Count -eq 0) {
        [PSCustomObject]@{
            DisplayName = $Group.DisplayName
            GroupId     = $Group.Id
        }
    }
}

$Results | Export-Csv "./EmptyEntraGroups.csv" -NoTypeInformation
$Results