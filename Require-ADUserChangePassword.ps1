
function Require-ADUserChangePassword {
  $user = Read-Host -Prompt "User"
  Set-ADUser -Identity $user -ChangePasswordAtLogon $true
}
