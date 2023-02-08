
Function Get-MassWindowsUpdate ($build) {
    if (-not $build) {$build = Read-Host -Prompt "Target Build"}
    $clients = _Get-Clients $build
    $readyclients = _Check-ReadyClients $clients
    write-output "# of Ready Clients:",$readyclients.count
    _Install-PSWindowsUpdate $readyclients
    _Start-WindowsUpdate $readyclients
    write-output "All update jobs have been scheduled"
}



Function Get-TargetedWindowsUpdate ($target) {
    if (-not $target) {$target = Read-Host -Prompt "Target Machine"}
    $readyclients = _Check-ReadyClients $target
    write-output "# of Ready Clients:",$readyclients.count
    _Install-PSWindowsUpdate $readyclients
    _Start-WindowsUpdate $readyclients
    write-output "Update job for $target has been scheduled"
}



Function _Get-Clients ($build) {
    # Retrieve the targeted clients list from Active Directory
    $clients = get-adcomputer -filter 'enabled -eq $True' -properties operatingsystem,operatingsystemversion | select name,operatingsystemversion,operatingsystem | where-object -filterscript {$_.operatingsystemversion -like "10.0 ($build*" -and $_.operatingsystem -notlike '*Server*'}
    
    Return $clients
}


Function _Check-ReadyClients ($clients) {
    # Narrow the target list down to just the clients that are currently online
    $readyclients = @(); foreach ($client in $clients) {if (test-connection $client.name -count 1 -erroraction ignore) {write-host $client.name,"yes"; $readyclients += $client} else {write-host $client.name,"no"}}; $readyclients
    
    Return $readyclients
}



Function _Install-PSWindowsUpdate ($readyclients) {
    invoke-command $readyclients.name -scriptblock {Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force; set-psrepository -name "PSGallery" -installationpolicy Trusted; install-module pswindowsupdate -confirm:$false; set-executionpolicy unrestricted; import-module pswindowsupdate}

}



Function _Start-WindowsUpdate ($readyclients) {
    invoke-command -computername $readyclients.name -script {register-scheduledjob -name WindowsUpdate -confirm:$false -script {ipmo PSWindowsUpdate; get-windowsupdate; install-windowsupdate -acceptall -autoreboot -verbose | out-file -filepath C:\PSWindowsUpdate.log; "Finished" | out-file -filepath C:\PSWindowsUpdate.log -append} -runnow}

}


Function Check-UpdateJobStatus ($readyclients) {
    # Check the status of the targets
    invoke-command -computername $readyclients.name -script {get-job} -erroraction silentlycontinue
}


Function Restart-UpdatedClients ($readyclients) {
    # Restarts the target
    foreach ($client in $readyclients) {
        if ($client.state -eq "Completed") {
            invoke-command -computername $client.pscomputername -script {restart-computer -force} -erroraction silentlycontinue
        }
    }
}


#invoke-command -computername $readyclients.name -script {get-content C:\PSWindowsUpdate.log} -erroraction silentlycontinue

#invoke-command -computername $readyclients.name -script {select-string -path "C:\PSWindowsUpdate.log" -pattern 'Finished'} -erroraction silentlycontinue
