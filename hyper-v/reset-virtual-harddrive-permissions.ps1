$VM = "Name"

$VMID = (Get-VM $VM | Select-Object -ExpandProperty VMID).Guid

$VMHDDs = Get-VMHardDiskDrive -VMName $VM

$VMHDDs | ForEach-Object {
    Write-Host "Updating Permissions: $($_.Path)"

    icacls.exe $($_.Path) /grant ($VMID + ":F")
}
