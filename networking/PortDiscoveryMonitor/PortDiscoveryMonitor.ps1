param(
    [switch]$Monitor
)

$Directory = "C:\Tools\PortDiscoveryMonitor\"
$LogDirectory = Join-Path -Path $Directory -ChildPath "Logs"
$CurrPorts = Join-Path -Path $Directory -ChildPath "\cports\cports.exe"
$ScriptPath = Join-Path -Path $Directory -ChildPath "PortDiscoveryMonitor.ps1"


function Get-CurrPorts {

    $CurrPortsURL = "https://www.nirsoft.net/utils/cports-x64.zip"
    $(Join-Path -Path $Directory -Child "cports-x64.zip") | ForEach-Object {
        Invoke-WebRequest -Uri $CurrPortsURL -OutFile $_
        Expand-Archive -Path $_ -DestinationPath $(Join-Path -Path $Directory -Child "cports") -Force
    }
    
}

function Watch-ListeningPorts {

    $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $LogFile = Join-Path -Path $LogDirectory -ChildPath ($Timestamp + ".xml")
    & $CurrPorts /sxml $LogFile `
    /StartAsHidden `
    /CaptureTime "900000" `
    /DisplayIPv6Ports 0 `
    /DisplayListening 1 `
    /DisplayEstablished 0 `
    /DisplayNoState 0 `
    /RunAsAdmin `

    # CurrPorts breaks out so PowerShell doesn't know to wait
    Start-Sleep -Seconds 902

    return $LogFile
    
}

function Export-FilteredCSV {
    param (
        [string]$FilePath
    )

    $CSVPath = Join-Path -Path $LogDirectory -ChildPath ((Get-Item -Path $FilePath).BaseName + ".csv")

    ([xml]$(Get-Content -Path $FilePath)).tcp_udp_ports_list.item |
    Where-Object { $_.state -like "Listening" } |
    Select-Object `
        process_path, 
        protocol, local_port, 
        local_port_name, 
        local_address, 
        state, 
        file_description |
    Export-Csv -NoTypeInformation -Path $CSVPath
    
}

function Set-ScheduledTask {

    $TaskName = "Port Discovery Monitor - Run Every 15 Minutes"

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $Action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" -Monitor"

    $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
        -RepetitionInterval (New-TimeSpan -Minutes 15) `
        -RepetitionDuration (New-TimeSpan -Days 1)

    $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances Parallel

    Register-ScheduledTask -TaskName $TaskName `
        -Action $Action `
        -Trigger $Trigger `
        -Principal $Principal `
        -Settings $Settings

}


if($Monitor){

    Write-Host "Port Discovery Monitor -- Monitoring Enabled" -ForegroundColor Green

    Write-Host "- Starting Monitor for 15 Minutes"
    $XMLFile = Watch-ListeningPorts
    Write-Host "Log Path: $XMLFile"

    Write-Host "- Parsing and Exporting into CSV"
    Export-FilteredCSV -FilePath $XMLFile

    Write-Host "- Cleaning Up"
    Remove-Item -Path $XMLFile -Force


}else{

    Write-Host "Port Discovery Monitor -- Running Initial Installation" -ForegroundColor Green

    # Creating important directories
    Write-Host "- Creating Essential Directories"
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null

    # Downloading CurrPorts
    Write-Host "- Downloading CurrPorts"
    Get-CurrPorts | Out-Null

    # Creating/Updating Scheduled Task
    Write-Host "- Creating/Setting Scheduled Task"
    Set-ScheduledTask | Out-Null

    # Making a Copy of Itself and Place In Directory
    Write-Host "- Copying Script into Run Directory"
    Copy-Item -Path $MyInvocation.MyCommand.Path -Destination $ScriptPath -Force | Out-Null

}