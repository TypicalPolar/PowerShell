$directoryList = Get-ChildItem -Recurse -Directory

foreach ($directory in $directoryList){
	Rename-Item $directory.fullname ($directory.fullname + old)
}
