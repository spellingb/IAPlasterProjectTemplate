#Requires -Module @{ ModuleName = 'InvokeBuild'; ModuleVersion = 5.7 }

[CmdletBinding()]
[System.Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingEmptyCatchBlock', '')]
[System.Diagnostics.CodeAnalysis.SuppressMessage('PSPossibleIncorrectComparisonWithNull', '')]

param (
	[string[]]$Tag,
	[ValidateSet('Major','Minor','Patch')]
	$DeploymentType = 'Patch'
)

# Ensure everything works in the most strict mode.
Set-StrictMode -Version Latest

#region Get OS
try {
	if ( $thething -eq $null){}
    $script:IsWindows = (-not (Get-Variable -Name IsWindows -ErrorAction Ignore)) -or $IsWindows
    $script:IsLinux = (Get-Variable -Name IsLinux -ErrorAction Ignore) -and $IsLinux
    $script:IsMacOS = (Get-Variable -Name IsMacOS -ErrorAction Ignore) -and $IsMacOS
    $script:IsCoreCLR = $PSVersionTable.ContainsKey('PSEdition') -and $PSVersionTable.PSEdition -eq 'Core'
}
catch { }

switch ($true) {
    { $IsWindows } {
        $OS = "Windows"
        if (-not ($IsCoreCLR)) {
            $OSVersion = $PSVersionTable.BuildVersion.ToString()
        }
    }
    { $IsLinux } {
        $OS = "Linux"
    }
    { $IsMacOs } {
        $OS = "OSX"
    }
    { $IsCoreCLR } {
        $OSVersion = $PSVersionTable.OS
    }
}
#endregion

#Ensure all Build Tools exist
Import-Module "$PSScriptRoot/Tools/BuildTools.psm1" -Force -ErrorAction Stop

$publishRepository = 'ArmorPosh'
$RepoRoot = $PSScriptRoot
$ModuleName = '<%=$PLASTER_PARAM_ModuleName%>'
$ModulePath = Join-Path $RepoRoot $ModuleName
$PublicFunctionsPath = Join-Path $ModulePath 'Public'
$DocsPath = Join-Path $RepoRoot 'docs'
$DocsLocale = 'en-US'
$ModuleManifestPath = Join-Path $ModulePath "$ModuleName.psd1"
$LocalBuildPath = Join-Path $RepoRoot 'build'

Add-BuildTask Init { Invoke-Init }

# Synopsis: Get the next Version for the build
Add-BuildTask GetVersion Init, {
	if (Test-Path $ModuleManifestPath) {
		$manifestVersion = [Version](Get-Metadata -Path $env:BHPSModuleManifest)

		$CurrentOnlineVersion = [Version](Find-Module -Name $env:BHProjectName).Version

		$env:CurrentOnlineVersion = [version]$CurrentOnlineVersion

		if ( 	( $manifestVersion.Major -gt $CurrentOnlineVersion.Major ) -or
				( $manifestVersion.Minor -gt $CurrentOnlineVersion.Minor ) -or
				( $manifestVersion.Build -gt $CurrentOnlineVersion.Build )
			) {
				$env:NextBuildVersion = [Version]( Step-Version $manifestVersion -By $DeploymentType)

			} else {
			$env:NextBuildVersion = [Version]( Step-Version $env:CurrentOnlineVersion -By $DeploymentType)
		}

		Try {
			$functionList = ( ( Get-ChildItem -Path $env:BHModulePath\Public -Recurse -Filter "*.ps1").BaseName )
			Update-ModuleManifest -Path $env:BHPSModuleManifest -ModuleVersion $env:NextBuildVersion -FunctionsToExport $functionList
			(Get-Content -Path $ModuleManifestPath) -replace "PSGet_$ModuleName", "$ModuleName" | Set-Content -Path $ModuleManifestPath
			(Get-Content -Path $ModuleManifestPath) -replace 'NewManifest', "$ModuleName" | Set-Content -Path $ModuleManifestPath
			(Get-Content -Path $ModuleManifestPath) -replace 'FunctionsToExport = ', 'FunctionsToExport = @(' | Set-Content -Path $ModuleManifestPath -Force
			(Get-Content -Path $ModuleManifestPath) -replace "$($functionList[-1])'", "$($functionList[-1])')" | Set-Content -Path $ModuleManifestPath -Force
		} catch {
			throw $_
		}
	} else {
		throw 'Versioning requires Module Manifest'
	}
}

#Synopsis: Run pester Tests
Add-BuildTask PesterTests {
	try {
		$testResultsFile = "$env:BHProjectPath\TestResult.xml"
		$result = Invoke-Pester -OutputFormat NUnitXml -OutputFile $testResultsFile -PassThru
		Remove-Item $testResultsFile -Force
		Assert-Build ($result.FailedCount -eq 0) "$($result.FailedCount) Pester test(s) failed."
	} catch {
		throw
	}
}

#Synopsis: Make Help Files
Add-BuildTask UpdateDocs  {
	# Check docs folder
	if (-not (Test-Path $DocsPath)){
		try{
			New-Item -Path $DocsPath -ItemType Directory
		} catch {
			throw 'could not create docs folder'
		}
	}
	# Check project structure
	if (-not ((Test-Path $DocsPath) -and (Test-Path $env:BHModulePath))) {
		throw "Repository structure does not look OK"
	} else {
		if (Get-Module -ListAvailable -Name platyPS) {
			# Import modules
			Import-Module platyPS
			Import-Module $env:BHModulePath -Force

			# Generate markdown for new cmdlets
			New-MarkdownHelp -Module $ModuleName -OutputFolder $docsPath -Locale $DocsLocale -UseFullTypeName -ErrorAction SilentlyContinue | Out-Null
			# Update markdown for existing cmdlets
			Update-MarkdownHelp -Path $docsPath -UseFullTypeName | Out-Null
			# Generate external help
			New-ExternalHelp -Path $docsPath -OutputPath (Join-Path -Path $BHModulePath -ChildPath $DocsLocale) -Force | Out-Null
		} else {
			throw "You require the platyPS module to generate new documentation"
		}
	}
}

#Synopsis: Show Debugging information
Add-Buildtask ShowInfo {
    Write-Build Gray
    Write-Build Gray ('Running in:                 {0}' -f $env:BHBuildSystem)
    Write-Build Gray '-------------------------------------------------------'
    Write-Build Gray
    Write-Build Gray ('Project name:               {0}' -f $env:BHProjectName)
    Write-Build Gray ('Project root:               {0}' -f $env:BHProjectPath)
    Write-Build Gray ('Build Path:                 {0}' -f $env:BHBuildOutput)
    Write-Build Gray ('Current (online) Version:   {0}' -f $env:CurrentOnlineVersion)
    Write-Build Gray '-------------------------------------------------------'
    Write-Build Gray
    Write-Build Gray ('Branch:                     {0}' -f $env:BHBranchName)
    Write-Build Gray ('Commit:                     {0}' -f $env:BHCommitMessage)
    Write-Build Gray ('Build #:                    {0}' -f $env:BHBuildNumber)
    Write-Build Gray ('Next Version:               {0}' -f $env:NextBuildVersion)
    Write-Build Gray '-------------------------------------------------------'
    Write-Build Gray
    Write-Build Gray ('PowerShell version:         {0}' -f $PSVersionTable.PSVersion.ToString())
    Write-Build Gray ('OS:                         {0}' -f $OS)
    Write-Build Gray ('OS Version:                 {0}' -f $OSVersion)
    Write-Build Gray
}

Add-BuildTask LocalBuild GetVersion, PesterTests, UpdateDocs, {
	#Create New Build folder
	$null = New-Item -Path "$env:BHBuildOutput\$env:BHProjectName\$env:NextBuildVersion" -ItemType Directory

	#copy Module to new Folder
	Copy-Item -Path "$env:BHModulePath/*" -Destination "$env:BHBuildOutput\$env:BHProjectName\$env:NextBuildVersion" -Recurse -Force

}

#Synopsis: Publish Build on Github and configured REpo
Add-BuildTask Publish Scrub, {
	Publish-Module -Path "$env:BHBuildOutput\$env:BHProjectName\$env:NextBuildVersion" -Repository $PublishRepository

	$releaseText = "Release version $env:NextBuildVersion"

    Write-Build Gray "git checkout $ENV:BHBranchName"
    cmd /c "git checkout $ENV:BHBranchName 2>&1"

    Write-Build Gray "git tag -a v$env:NextBuildVersion -m `"$releaseText`""
	cmd /c "git tag -a v$env:NextBuildVersion -m `"$releaseText`" 2>&1"

	Write-Build Gray "git commit -a -m '$releaseText'"
	cmd /c "git commit -a -m '$releaseText' --verbose"

	Write-Build gray "git push --verbose"
	cmd /c "git push --verbose 2>&1"

    Write-Build Gray "git push origin v$env:NextBuildVersion"
    cmd /c "git push origin v$env:NextBuildVersion 2>&1"
}

Add-BuildTask . ShowInfo, LocalBuild, Publish
