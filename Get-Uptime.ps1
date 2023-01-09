function Get-Uptime($DeviceID) {
  if(-not ($DeviceID)) {
    write-host("Please provide a computer name.")
    exit
   }
  $BootUpTime = (Get-CimInstance -ClassName win32_OperatingSystem -ComputerName $DeviceID).LastBootUpTime
  $CurrentDate = Get-Date
  $uptime = $CurrentDate - $BootUpTime
  $uptime | select days,hours,minutes
 }
