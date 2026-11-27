param(
    [string]$Log
)

try {
    $ErrorActionPreference = 'Stop'
    $repo = Split-Path -Parent $PSScriptRoot
    $localRoot = Join-Path $env:LOCALAPPDATA 'victory'
    $logsDir = Join-Path $localRoot 'logs'
    $dataDir = Join-Path $localRoot 'data'
    $temp = $null

    try {
        if (-not $Log -and (Test-Path -LiteralPath $logsDir -PathType Container)) {
            $newest = Get-ChildItem -LiteralPath $logsDir -Filter 'victory-nvidia-*.log' -File |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest) { $Log = $newest.FullName }
        }
        $allowedLogRoot = [IO.Path]::GetFullPath($logsDir).TrimEnd('\') + '\'
        if ($Log -and (Test-Path -LiteralPath $Log -PathType Leaf)) {
            $fullLog = [IO.Path]::GetFullPath($Log)
            if ($fullLog.StartsWith($allowedLogRoot, [StringComparison]::OrdinalIgnoreCase)) { $Log = $fullLog }
            else { $Log = $null }
        } else { $Log = $null }

        $downloads = Join-Path $env:USERPROFILE 'Downloads'
        if (Test-Path -LiteralPath $downloads -PathType Container) {
            $reportDir = Join-Path $downloads 'VIctory-reports'
        } else {
            $reportDir = Join-Path $localRoot 'reports'
        }
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $zipPath = Join-Path $reportDir ("VIctory-report-{0}.zip" -f $stamp)
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('VIctory-report-{0}' -f [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp -Force | Out-Null

        if ($Log) { Copy-Item -LiteralPath $Log -Destination (Join-Path $temp 'run.log') -Force }

        if (Test-Path -LiteralPath $dataDir -PathType Container) {
            $recentCrashes = Get-ChildItem -LiteralPath $dataDir -Filter 'crashes.log' -File -Recurse |
                Where-Object { $_.LastWriteTime -ge (Get-Date).AddHours(-24) }
            if ($recentCrashes) {
                $crashText = New-Object System.Text.StringBuilder
                foreach ($crash in $recentCrashes) {
                    [void]$crashText.AppendLine(('--- ' + $crash.FullName + ' ---'))
                    [void]$crashText.AppendLine([IO.File]::ReadAllText($crash.FullName))
                    [void]$crashText.AppendLine('')
                }
                [IO.File]::WriteAllText((Join-Path $temp 'crashes.log'), $crashText.ToString(), [System.Text.UTF8Encoding]::new($false))
            }
        }

        $localSettings = Join-Path $localRoot 'victory-settings.txt'
        if (Test-Path -LiteralPath $localSettings -PathType Leaf) {
            Copy-Item -LiteralPath $localSettings -Destination (Join-Path $temp 'victory-settings.txt') -Force
        }
        $repoSettings = Join-Path $repo 'victory-settings.txt'
        if (Test-Path -LiteralPath $repoSettings -PathType Leaf) {
            Copy-Item -LiteralPath $repoSettings -Destination (Join-Path $temp 'repository-victory-settings.txt') -Force
        }

        if ($env:VICTORY_CACHE_DIR) { $cacheDir = $env:VICTORY_CACHE_DIR }
        else { $cacheDir = Join-Path $localRoot 'cache' }
        $pipelineDir = Join-Path $cacheDir 'pipelines'
        foreach ($pipelineFile in @('early-pipelines.txt', 'slow-pipelines.txt', 'warm-done.txt', 'warm-bad.txt')) {
            $source = Join-Path $pipelineDir $pipelineFile
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                Copy-Item -LiteralPath $source -Destination (Join-Path $temp $pipelineFile) -Force
            }
        }

        $summary = New-Object System.Text.StringBuilder
        [void]$summary.AppendLine('VIctory run report')
        [void]$summary.AppendLine(('Created: {0:yyyy-MM-dd HH:mm:ss zzz}' -f (Get-Date)))
        if ($Log) { [void]$summary.AppendLine(('Run log: {0}' -f (Split-Path -Leaf $Log))) }
        else { [void]$summary.AppendLine('Run log: not found') }
        [void]$summary.AppendLine(('Pipeline data folder: {0}' -f $pipelineDir))
        if ($Log) {
            $bytes = [IO.File]::ReadAllBytes($Log)
            if ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
                $logText = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
            } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {
                $logText = [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
            } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
                $logText = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
            } else {
                $logText = [System.Text.UTF8Encoding]::new($false, $false).GetString($bytes)
            }
            $preloadLines = @($logText -split '\r?\n' | Where-Object { $_ -match '(?i)preload|shader|pipeline' })
            [void]$summary.AppendLine(('Shader/pipeline/preload log lines: {0}' -f $preloadLines.Count))
            if ($preloadLines.Count -gt 0) {
                $preloadText = $preloadLines -join [Environment]::NewLine
                [IO.File]::WriteAllText((Join-Path $temp 'shader-pipeline-lines.txt'), $preloadText, [System.Text.UTF8Encoding]::new($false))
            }
        }
        [IO.File]::WriteAllText((Join-Path $temp 'summary.txt'), $summary.ToString(), [System.Text.UTF8Encoding]::new($false))

        $system = New-Object System.Text.StringBuilder
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        [void]$system.AppendLine(('Windows: {0}; version {1}; build {2}; {3}' -f $os.Caption, $os.Version, $os.BuildNumber, $os.OSArchitecture))
        $processors = @(Get-CimInstance -ClassName Win32_Processor)
        $cpuNames = @($processors | ForEach-Object { $_.Name } | Where-Object { $_ } | Select-Object -Unique)
        $threads = ($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        [void]$system.AppendLine(('CPU: {0}; logical threads: {1}' -f ($cpuNames -join '; '), $threads))
        [void]$system.AppendLine(('RAM: {0} MB; commit limit: {1} MB' -f [Math]::Round(($os.TotalVisibleMemorySize / 1024), 0), [Math]::Round(($os.TotalVirtualMemorySize / 1024), 0)))
        [void]$system.AppendLine('Graphics cards:')
        foreach ($card in @(Get-CimInstance -ClassName Win32_VideoController)) {
            $memory = if ($card.AdapterRAM) { [Math]::Round(([double]$card.AdapterRAM / 1048576.0), 0) } else { 'unknown' }
            [void]$system.AppendLine(('  {0}; driver {1}; memory {2} MB' -f $card.Name, $card.DriverVersion, $memory))
        }
        $hwsch = 'not present'
        $key = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        if (Test-Path -LiteralPath $key) {
            $value = (Get-ItemProperty -LiteralPath $key -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
            if ($null -ne $value) { $hwsch = ('HwSchMode={0}' -f $value) }
        }
        [void]$system.AppendLine(('Hardware-accelerated GPU scheduling: {0}' -f $hwsch))
        $sl = Join-Path $env:LOCALAPPDATA 'victory\nvidia-sdk\Streamline\bin\x64\sl.interposer.dll'
        if (-not (Test-Path -LiteralPath $sl -PathType Leaf)) {
            $sl = Join-Path $repo 'nvidia-sdk\Streamline\bin\x64\sl.interposer.dll'
        }
        if (Test-Path -LiteralPath $sl -PathType Leaf) {
            [void]$system.AppendLine(('sl.interposer.dll: present; version {0}' -f [Diagnostics.FileVersionInfo]::GetVersionInfo($sl).FileVersion))
        } else { [void]$system.AppendLine('sl.interposer.dll: not present') }
        $gitCommand = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCommand -and (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
            $savedPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $commit = (& $gitCommand.Source -C $repo rev-parse HEAD 2>$null | Out-String).Trim()
                $gitCode = $LASTEXITCODE
            } finally { $ErrorActionPreference = $savedPreference }
            if ($gitCode -eq 0 -and $commit) { [void]$system.AppendLine(('Repository commit: {0}' -f $commit)) }
            else { [void]$system.AppendLine('Repository commit: unavailable') }
        } else { [void]$system.AppendLine('Repository commit: unavailable (release source archive)') }
        [IO.File]::WriteAllText((Join-Path $temp 'system.txt'), $system.ToString(), [System.Text.UTF8Encoding]::new($false))

        Compress-Archive -Path (Join-Path $temp '*') -DestinationPath $zipPath -Force
        Write-Host $summary.ToString()
        Write-Host ('Report ZIP: {0}' -f $zipPath)
    } catch {
        Write-Host ('Report creation failed: {0}' -f ([Regex]::Replace($_.Exception.Message, '\s+', ' ')))
    } finally {
        if ($temp -and (Test-Path -LiteralPath $temp)) {
            try { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction Stop } catch { }
        }
    }
} catch {
    Write-Host ('Report creation failed: {0}' -f ([Regex]::Replace($_.Exception.Message, '\s+', ' ')))
}
exit 0
