$removeList = Get-Printer | Where-Object { $_.Type -ne 'Local'}
$removeList | foreach {
  Remove-Printer -Name $_.Name
}
