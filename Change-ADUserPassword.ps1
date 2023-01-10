
function Change-ADUserPassword {
  $user = Read-Host -Prompt "User"
  $newpass = Read-Host -Prompt "New Password" -MaskInput
  $requirechange = Read-Host -Prompt "Require password change at next login?"
  Import-Module ActiveDirectory
  Set-ADAccountPassword -Identity $user -Reset -NewPassword (ConvertTo-SecureString -AsPlainText $newpass -Force)
  Unlock-ADAccount -Identity $user
  
  if (-not($requirechange)) {
    $requirechange = $true
  } elseif ($requirechange -ne "false") {
    $requirechange = $true
  }
}


Set-ADUser -Identity $user -ChangePasswordAtLogon $true
