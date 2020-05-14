$logFile = "c:\tools\print-migration.log"
$sourceServer = 'oldserver'
$destinationServer = 'newserver'
$errorCount = 0

if (!(Test-Path c:\tools\ -PathType Container)) {
    New-Item -ItemType Directory -Force -Path c:\tools\
}
Function logWrite
{
   Param ([string]$logstring)
   Add-content $logFile -value $logstring
}

logWrite 'Gathering list of printers'
$printList = Get-Printer | Where-Object { $_.ComputerName -eq $sourceServer}
$newprintList = Get-Printer -ComputerName $destinationServer

logWrite 'Replacing printers if available on new print server'
$printlist | foreach {
    $printnameOnly = $_.Name -replace "[\\$sourceServer\/]"
    if ($newprintList.name.Contains($printnameOnly)) {
      logWrite "Found $printnameOnly on new server. Attempting to replace."
      Add-Printer -ConnectionName "\\$destinationServer\$printnameOnly" -ErrorVariable installError
      if ($installError) {
        logWrite "[!] Installation of $printnameOnly was unsuccessful!"
        $errorCount += 1
      }
      else {
        logWrite "$printnameOnly was successfully installed!"
        logWrite "Removing link from the old printer server for $printnameOnly."
        Remove-Printer -Name $_.Name
      }
    }
    else {
      logWrite "[!] $printnameOnly is not available on the new server and thus was skipped."
      $errorCount += 1
    }
}
write-host "[!] You had a total of $errorCount errors. Check logs for details."
