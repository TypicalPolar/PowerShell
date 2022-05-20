$inventory_File = "C:\tools\printerInventoryFile.csv" # Output File Location
$printer_List = Get-Printer | Where-Object { $_.PortName -like "192.168*"} # Listing Network Printers

# Creating Inventory File if it's Missing
if(-not(Test-path $inventory_File -PathType leaf))
{
	write-host "[!] Inventory File Missing. Generating Log File"
	{} | Select "end_User","workstation_Name","printer_Name","printer_IP","printer_Device" | Export-Csv $inventory_File
}

$printer_data = Import-Csv $inventory_File # Importing Inventory File
$existing_data = $printer_data # Copying Inventory File into a separate variable for comparing later on
$end_User = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name.split("\")[1] # Had Issues with Escapes. Removes Domain \

# Logging Printer Inventory
foreach ($installed_printer in $printer_List){
	if($existing_data.printer_Name.Contains($installed_printer.Name) -and $existing_data.printer_Name.Contains($installed_printer.Name)) # Checking Printer Isn't Already Inventoried
	{
		write-host "Printer is already inventoried, excluding from inventory."
	} else
	{
		$printer_data.end_User = [Security.Principal.WindowsIdentity]::GetCurrent().name
		$printer_data.workstation_Name = [System.NET.DNS]::GetHostByName('').hostname
		$printer_data.printer_Name = $installed_printer.Name
		$printer_data.printer_IP = $installed_printer.PortName
		$printer_data.printer_Device = $installed_printer.DriverName
		$printer_data | Export-CSV $inventory_File –Append # Appending Inventory File
	}
}
