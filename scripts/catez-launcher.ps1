$ErrorActionPreference = 'Stop'
$launcherVersion = 'v1'
$repoApi = 'https://api.github.com/repos/MfDev0/CATEez/releases/latest'
$installRoot = Join-Path $env:LOCALAPPDATA 'CATEez\projects'
$pathFile = Join-Path $env:LOCALAPPDATA 'CATEez\game-exe-path.txt'
$activeProjectFile = Join-Path $env:LOCALAPPDATA 'CATEez\active-project-path.txt'
$tempRoot = $null
$forceProjectUpdate = $false
$exitForUpdate = $false

try {
    Write-Host ('CATEez game launcher {0}' -f $launcherVersion)
    Write-Host 'Checking the latest CATEez project release...'
    $release = Invoke-RestMethod -Uri $repoApi -Headers @{ 'User-Agent' = 'CATEez-Launcher' }
    $projectVersion = [string]$release.tag_name
    if ($projectVersion -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw 'The release has an invalid version tag.'
    }
    $projectAsset = @($release.assets | Where-Object { $_.name -eq 'CATEez-project.zip' } | Select-Object -First 1)
    if ($projectAsset.Count -eq 0) {
        throw ('The project package for {0} is not ready yet. Try again shortly.' -f $projectVersion)
    }

    Write-Host ('Latest repository version: {0}' -f $projectVersion)
    Write-Host 'Press U then Enter to refresh the project files and update this launcher if a newer EXE is published.'
    $updateChoice = (Read-Host 'Press U to update, or Enter to continue').Trim()
    if ($updateChoice -match '^(?i)u$') {
        $forceProjectUpdate = $true
        $launcherAsset = @($release.assets | Where-Object { $_.name -eq 'CATEez-Launcher-v1.exe' } | Select-Object -First 1)
        if ($launcherAsset.Count -gt 0) {
            $currentExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if ([IO.Path]::GetExtension($currentExe) -ieq '.exe' -and
                [IO.Path]::GetFileName($currentExe) -match '^CATEez-Launcher-.*\.exe$') {
                $updateDir = Join-Path $env:LOCALAPPDATA 'CATEez\updates'
                New-Item -ItemType Directory -Path $updateDir -Force | Out-Null
                $stagedExe = Join-Path $updateDir 'CATEez-Launcher-v1.exe.pending'
                Write-Host 'Checking the v1 launcher file for an update...'
                Invoke-WebRequest -Uri ([string]$launcherAsset[0].browser_download_url) -OutFile $stagedExe -UseBasicParsing
                if ((Get-Item -LiteralPath $stagedExe).Length -lt 16384) {
                    throw 'The downloaded launcher update is unexpectedly small.'
                }
                $oldHash = (Get-FileHash -LiteralPath $currentExe -Algorithm SHA256).Hash
                $newHash = (Get-FileHash -LiteralPath $stagedExe -Algorithm SHA256).Hash
                if ($oldHash -ne $newHash) {
                    $helperPath = Join-Path $env:TEMP ('CATEez-update-{0}.ps1' -f [Guid]::NewGuid().ToString('N'))
                    $helperText = @"
`$parentId = $PID
`$staged = '$($stagedExe.Replace("'", "''"))'
`$target = '$($currentExe.Replace("'", "''"))'
for (`$i = 0; `$i -lt 120; `$i++) {
    if (-not (Get-Process -Id `$parentId -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Seconds 1
}
if (Get-Process -Id `$parentId -ErrorAction SilentlyContinue) { exit 1 }
for (`$i = 0; `$i -lt 30; `$i++) {
    try {
        Copy-Item -LiteralPath `$staged -Destination `$target -Force -ErrorAction Stop
        Start-Process -FilePath `$target
        Remove-Item -LiteralPath `$staged -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue
        exit 0
    } catch { Start-Sleep -Seconds 2 }
}
Write-Error 'Could not replace the launcher executable.'
exit 1
"@
                    [IO.File]::WriteAllText($helperPath, $helperText, [System.Text.UTF8Encoding]::new($false))
                    $powershell = Join-Path $PSHOME 'powershell.exe'
                    if (-not (Test-Path -LiteralPath $powershell)) { $powershell = 'powershell.exe' }
                    Start-Process -FilePath $powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $helperPath)) -WindowStyle Hidden
                    Write-Host 'The v1 launcher update is downloaded. Closing this window so the same EXE can be replaced and reopened.'
                    $exitForUpdate = $true
                    return
                } else {
                    Remove-Item -LiteralPath $stagedExe -Force -ErrorAction SilentlyContinue
                    Write-Host 'This v1 launcher EXE is already current; refreshing the project files anyway.'
                }
            } else {
                Write-Host 'A launcher update is available, but automatic replacement only works from the CATEez Launcher EXE.'
            }
        } else {
            Write-Host 'No v1 launcher EXE is attached to the latest release yet; refreshing the project files.'
        }
    }
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    $projectRoot = $null
    $installPrefix = [IO.Path]::GetFullPath($installRoot).TrimEnd('\') + '\'
    if (Test-Path -LiteralPath $activeProjectFile -PathType Leaf) {
        $savedProjectRoot = [IO.File]::ReadAllText($activeProjectFile).Trim()
        if ($savedProjectRoot) {
            $savedProjectRoot = [IO.Path]::GetFullPath($savedProjectRoot)
            if ($savedProjectRoot.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase) -and
                (Test-Path -LiteralPath $savedProjectRoot -PathType Container)) {
                $projectRoot = $savedProjectRoot
            }
        }
    }
    if (-not $projectRoot) {
        $installed = foreach ($candidate in Get-ChildItem -LiteralPath $installRoot -Directory -ErrorAction SilentlyContinue) {
            $marker = Join-Path $candidate.FullName '.catez-version'
            $candidateEngine = Join-Path $candidate.FullName 'target\release\victory.exe'
            $candidateRunner = Join-Path $candidate.FullName 'scripts\play-nvidia.ps1'
            if ((Test-Path -LiteralPath $marker -PathType Leaf) -and
                (Test-Path -LiteralPath $candidateEngine -PathType Leaf) -and
                (Test-Path -LiteralPath $candidateRunner -PathType Leaf)) {
                $tag = [IO.File]::ReadAllText($marker).Trim()
                $version = $null
                try { $version = [version]($tag.TrimStart('v')) } catch { }
                if ($version) { [pscustomobject]@{ Path = $candidate.FullName; Version = $version } }
            }
        }
        $latestInstalled = $installed | Sort-Object Version -Descending | Select-Object -First 1
        if ($latestInstalled) { $projectRoot = $latestInstalled.Path }
        else { $projectRoot = Join-Path $installRoot 'current' }
    }
    $versionFile = Join-Path $projectRoot '.catez-version'
    $runner = Join-Path $projectRoot 'scripts\play-nvidia.ps1'
    $engine = Join-Path $projectRoot 'target\release\victory.exe'
    $installedVersion = ''
    if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
        $installedVersion = [IO.File]::ReadAllText($versionFile).Trim()
    }

    if ($forceProjectUpdate -or $installedVersion -ne $projectVersion -or
        -not (Test-Path -LiteralPath $runner -PathType Leaf) -or
        -not (Test-Path -LiteralPath $engine -PathType Leaf)) {
        Write-Host ('Downloading CATEez project {0}...' -f $projectVersion)
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('catez-{0}' -f [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $archivePath = Join-Path $tempRoot 'CATEez-project.zip'
        $extractPath = Join-Path $tempRoot 'project'
        Invoke-WebRequest -Uri ([string]$projectAsset[0].browser_download_url) -OutFile $archivePath -UseBasicParsing
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force

        $stagedRunner = Join-Path $extractPath 'scripts\play-nvidia.ps1'
        $stagedEngine = Join-Path $extractPath 'target\release\victory.exe'
        if (-not (Test-Path -LiteralPath $stagedRunner -PathType Leaf) -or
            -not (Test-Path -LiteralPath $stagedEngine -PathType Leaf)) {
            throw 'The downloaded project package is incomplete.'
        }
        [IO.File]::WriteAllText((Join-Path $extractPath '.catez-version'), $projectVersion, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $projectRoot) {
            Remove-Item -LiteralPath $projectRoot -Recurse -Force
        }
        Move-Item -LiteralPath $extractPath -Destination $projectRoot
        Write-Host ('Downloaded project version: {0}' -f $projectVersion)
    } else {
        Write-Host ('Project version already installed: {0}' -f $installedVersion)
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $activeProjectFile) -Force | Out-Null
    [IO.File]::WriteAllText($activeProjectFile, $projectRoot, [System.Text.UTF8Encoding]::new($false))

    $gamePath = ''
    if (Test-Path -LiteralPath $pathFile -PathType Leaf) {
        $savedPath = [IO.File]::ReadAllText($pathFile).Trim()
        if ($savedPath -and (Test-Path -LiteralPath $savedPath -PathType Leaf)) {
            Write-Host ''
            Write-Host ('Saved game EXE: {0}' -f $savedPath)
            $choice = (Read-Host 'Press Enter to use it, or C then Enter to change the path').Trim()
            if ($choice -notmatch '^(?i)c$') { $gamePath = $savedPath }
        } else {
            Write-Host 'The saved game path is no longer valid; enter the new path.'
        }
    }
    if (-not $gamePath) {
        Write-Host ''
        Write-Host 'Paste the full path to your game dump executable.'
        Write-Host 'Example: D:\Games\MyDump\game_scarlett_master.exe'
        $gamePath = (Read-Host 'Game dump EXE path').Trim()
        if ($gamePath.Length -ge 2 -and $gamePath[0] -eq '"' -and $gamePath[$gamePath.Length - 1] -eq '"') {
            $gamePath = $gamePath.Substring(1, $gamePath.Length - 2)
        }
        if ($gamePath.Length -ge 2 -and $gamePath[0] -eq "'" -and $gamePath[$gamePath.Length - 1] -eq "'") {
            $gamePath = $gamePath.Substring(1, $gamePath.Length - 2)
        }
        if ([IO.Path]::GetExtension($gamePath) -ine '.exe' -or
            -not (Test-Path -LiteralPath $gamePath -PathType Leaf)) {
            throw 'That path is not an existing game .exe file.'
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $pathFile) -Force | Out-Null
        [IO.File]::WriteAllText($pathFile, $gamePath, [System.Text.UTF8Encoding]::new($false))
        Write-Host 'Game EXE path saved. Press C at the next prompt to change it.'
    }

    $streamlineDir = Join-Path $env:LOCALAPPDATA 'victory\nvidia-sdk\Streamline\bin\x64'
    if ($env:VICTORY_STREAMLINE_DIR -and (Test-Path -LiteralPath (Join-Path $env:VICTORY_STREAMLINE_DIR 'sl.interposer.dll'))) {
        $streamlineDir = $env:VICTORY_STREAMLINE_DIR
    }
    if (-not (Test-Path -LiteralPath (Join-Path $streamlineDir 'sl.interposer.dll'))) {
        Write-Host ''
        Write-Host 'DLSS Performance and NVIDIA frame generation need NVIDIA Streamline files (~70 MB).'
        Write-Host 'They will be downloaded from NVIDIA and kept under your LocalAppData folder.'
        $answer = (Read-Host 'Download the NVIDIA files now? [Y/n]').Trim()
        if (-not $answer -or $answer -notmatch '^(?i)n') {
            Write-Host 'Downloading NVIDIA files from the project command...'
            $savedPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & $engine get-dlss
                $downloadExit = $LASTEXITCODE
            } finally { $ErrorActionPreference = $savedPreference }
            if ($downloadExit -eq 0 -and (Test-Path -LiteralPath (Join-Path $streamlineDir 'sl.interposer.dll'))) {
                Write-Host 'NVIDIA files are ready.'
            } else {
                Write-Host 'NVIDIA files were not installed; the game will start without DLSS/frame generation.'
            }
        } else {
            Write-Host 'Continuing without NVIDIA files; DLSS/frame generation will be unavailable.'
        }
    }
    if (Test-Path -LiteralPath (Join-Path $streamlineDir 'sl.interposer.dll')) {
        $env:VICTORY_STREAMLINE_DIR = $streamlineDir
    }

    Write-Host ''
    Write-Host ('Starting {0}: Series S profile, DLSS Performance, 3x requested, shaders/pipelines preloaded.' -f $projectVersion)
    Write-Host 'RTX 40-series cards support up to 2x DLSS frame generation; the project will use the card limit.'
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $runner -Exe $gamePath -SeriesS -Dlss performance -FrameGen -FrameGenX 3 -Preload
    } finally {
        $ErrorActionPreference = $savedPreference
    }
} catch {
    $message = [Regex]::Replace($_.Exception.Message, '\s+', ' ')
    Write-Host ('CATEez launcher error: {0}' -f $message)
} finally {
    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop } catch { }
    }
    if (-not $exitForUpdate) {
        Write-Host ''
        try { Read-Host 'Press Enter to close' | Out-Null } catch { }
    }
}
