$Directory = "C:\Tools\PortDiscoveryMonitor\"
$LogDirectory = Join-Path -Path $Directory -ChildPath "Logs"
$CurrPorts = Join-Path -Path $Directory -ChildPath "\cports\cports.exe"

New-Item -ItemType Directory -Path $Directory -Force
New-Item -ItemType Directory -Path $LogDirectory -Force


function Get-CurrPorts {

    $CurrPortsURL = "https://www.nirsoft.net/utils/cports-x64.zip"
    $(Join-Path -Path $Directory -Child "cports-x64.zip") | ForEach-Object {
        Invoke-WebRequest -Uri $CurrPortsURL -OutFile $_
        Expand-Archive -Path $_ -DestinationPath $(Join-Path -Path $Directory -Child "cports") -Force
    }
    
}

function Watch-ListeningPorts {

    #/CaptureTime "54000" `
    $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $LogFile = Join-Path -Path $LogDirectory -ChildPath ($Timestamp + ".xml")
    & $CurrPorts /sxml $LogFile `
    /StartAsHidden `
    /CaptureTime "120" `
    /DisplayIPv6Ports 0 `
    /DisplayListening 1 `
    /DisplayEstablished 0 `
    /DisplayNoState 0 `
    /RunAsAdmin `

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

if(Test-Path -path $CurrPorts){

    Write-Host "CurrPorts Detected!"

}else{

    Write-Host "Downloading CurrPorts"
    Get-CurrPorts
    
}