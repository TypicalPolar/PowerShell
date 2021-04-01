$directoryList = Get-ChildItem -Directory

foreach ($directory in $directoryList){
    # Renaming old folder
    Write-Progress -Activity 'Recreating Directory' -Status 'Renaming old folder' -PercentComplete 0
    $oldPath = ($directory.fullname + '.old')
	Rename-Item $directory.fullname $oldPath

    # Creating new folder
    Write-Progress -Activity 'Recreating Directory' -Status 'Creating new folder' -PercentComplete 25
    New-Item -ItemType "directory" -Path $directory.fullname

    # Transferring Content
    Write-Progress -Activity 'Recreating Directory' -Status 'Migrating to new folder' -PercentComplete 50
	robocopy $oldPath $directory.fullname /MIR /MOVE /MT:25

    # Checking for unmoved files and Cleanup
    Write-Progress -Activity 'Recreating Directory' -Status 'Removing old folder' -PercentComplete 75
    $isEmpty = Get-ChildItem $oldPath | Measure-Object
    if ( $isEmpty.Count -eq 0 ){
    Write-Output "Successfully moved: $($directory.fullname)"
    Remove-Item $oldPath -Force
    }
    else{
    Write-warning "Failure to move content: $($directory.fullname) (Count Count = $($isEmpty) )"
    }

    # Complete
    Write-Progress -Activity 'Recreating Directory' -Status 'Complete' -PercentComplete 100
}
