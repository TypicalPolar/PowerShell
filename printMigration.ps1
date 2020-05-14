$sourceServer = 'oldserver'
$destinationServer = 'newserver'
$errorCount = 0

Write-host 'Gathering list of printers'
$printList = Get-Printer | Where-Object { $_.ComputerName -eq $sourceServer}
$newprintList = Get-Printer -ComputerName $destinationServer

Write-host 'Replacing printers if available on new print server'
$printlist | foreach {
    $printnameOnly = $_.Name -replace "[\\$sourceServer\/]"
    if ($newprintList.name.Contains($printnameOnly)) {
      write-host "Found $printnameOnly on new server. Attempting to replace."
      Add-Printer -ConnectionName "\\$destinationServer\$printnameOnly" -ErrorVariable installError
      if ($installError) {
        write-host "[!] Installation of $printnameOnly was unsuccessful!"
        $errorCount += 1
      }
      else {
        write-host "$printnameOnly was successfully installed!"
        write-host "Removing link from the old printer server for $printnameOnly."
        Remove-Printer -Name $_.Name
      }
    }
    else {
      write-host "[!] $printnameOnly is not available on the new server and thus was skipped."
      $errorCount += 1
    }
}
write-host "[!] You had a total of $errorCount errors. Check logs for details."
