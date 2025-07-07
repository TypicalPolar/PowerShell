param(
    [switch]$Monitor,
    [switch]$Merge
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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
    $EscapedScriptPath = $ScriptPath.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    $XmlPath = "$env:TEMP\TaskData.xml"
    $StartTime = (Get-Date -Hour 0 -Minute 0 -Second 0).ToString("yyyy-MM-ddTHH:mm:ss")
    
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

$xmlContent = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Run monitoring script every 15 minutes forever</Description>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>SYSTEM</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowHardTerminate>true</AllowHardTerminate>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2025-07-06T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
      <Repetition>
        <Interval>PT15M</Interval>
        <Duration>P9999D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </CalendarTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File "C:\Tools\PortDiscoveryMonitor\PortDiscoveryMonitor.ps1" -Monitor</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    $xmlContent | Out-File -FilePath $XmlPath -Encoding Unicode
    schtasks /Create /TN $TaskName /XML $XmlPath /RU SYSTEM /F

}

function Set-ScheduledMergeTask {

    $TaskName = "Port Discovery Monitor - Daily Consolidation"

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $Action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" -Merge"

    $Trigger = New-ScheduledTaskTrigger -Daily -At "12:30AM"

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

function Merge-IntoDailyCSVs {
    param (
        $Date 
    )
    
    $Files = Get-ChildItem "$LogDirectory\*$Date*.csv"

    if ($Files) {
        $OutFile = "$LogDirectory\$Date.csv"
        $Files | Select-Object -First 1 | ForEach-Object {
            Get-Content $_ | Out-File $OutFile -Encoding UTF8
        }
        $Files | Select-Object -Skip 1 | ForEach-Object {
            Get-Content $_ | Select-Object -Skip 1 | Out-File $OutFile -Append -Encoding UTF8
        }
        $Files | Remove-Item -Force
        Write-Host "- Files have been merged and cleaned."
    } else {
        Write-Host "No matching files found for $Date."
    }

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


}elseif ($Merge) {
    
    Write-Host "Port Discovery Monitor -- Daily Merge" -ForegroundColor Green

    Merge-IntoDailyCSVs -Date (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")

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
    Set-ScheduledMergeTask | Out-Null

    # Making a Copy of Itself and Place In Directory
    Write-Host "- Copying Script into Run Directory"
    Copy-Item -Path $MyInvocation.MyCommand.Path -Destination $ScriptPath -Force | Out-Null

}