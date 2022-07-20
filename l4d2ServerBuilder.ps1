$pluginRepositoryPath = "c:\l4d2-serverbuilder\repository"

function Check-PluginFolder {
	param (
		[Parameter(Mandatory)]
		[string]$RepositoryPath
	)

	write-host "Checking for Builder Information"

	$pluginFolderList = Get-ChildItem -Path $RepositoryPath

	$buildinfoSuccess = $null
	$buildinfoSuccess = @{}

	foreach ($pluginFolder in $PluginFolderList) {
		$builderFolderLocation = $pluginFolder.FullName + "\builderinfo.csv"
		if(Test-Path $builderFolderLocation -PathType Leaf){
			write-host "- Found Builder Information File in" $pluginFolder.Name -ForegroundColor DarkGreen
			$buildinfoSuccess.add($pluginFolder.FullName,$builderFolderLocation)
		}
		else
		{
			write-host "- Builder Information File Missing in" $pluginFolder.Name -ForegroundColor Red
		}
	}

	return $buildinfoSuccess
}

function Read-BuilderInformation {
	param (
		[Parameter(Mandatory)]
		[string[]]$requiringReading
	)
}

$pluginswithBuildInfo = Check-PluginFolder $pluginRepositoryPath
$pluginswithBuildInfo
