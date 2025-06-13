$Directory = "C:\Tools\PortDiscoveryMonitor\"
$CurrPorts = Join-Path -Path $Directory -ChildPath "\cports\cports.exe"

New-Item -ItemType Directory -Path $Directory -Force


function Get-CurrPorts {

    $CurrPortsURL = "https://www.nirsoft.net/utils/cports-x64.zip"
    $(Join-Path -Path $Directory -Child "cports-x64.zip") | ForEach-Object {
        Invoke-WebRequest -Uri $CurrPortsURL -OutFile $_
        Expand-Archive -Path $_ -DestinationPath $(Join-Path -Path $Directory -Child "cports") -Force
    }
    
}

if(Test-Path -path $CurrPorts){

    Write-Host "CurrPorts Detected!"

}else{

    Write-Host "Downloading CurrPorts"
    Get-CurrPorts
    
}