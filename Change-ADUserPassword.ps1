
function Change-ADUserPassword {
  $user = Read-Host -Prompt "User"
  $newpass = Read-Host -Prompt "New Password" -MaskInput
  Import-Module ActiveDirectory
  Set-ADAccountPassword -Identity $user -Reset -NewPassword (ConvertTo-SecureString -AsPlainText $newpass -Force)
  Unlock-ADAccount -Identity $user
}
