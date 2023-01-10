

function Get-Top {
  ps | sort cpu -descending | select -first 30
}
