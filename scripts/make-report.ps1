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
        if (-not $Log) {
            if (Test-Path -LiteralPath $logsDir -PathType Container) {
                $newest = Get-ChildItem -LiteralPath $logsDir -Filter 'foxhound-*.log' -File |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($newest) { $Log = $newest.FullName }
            }
        }

        $allowedLogRoot = [IO.Path]::GetFullPath($logsDir).TrimEnd('\') + '\'
        if ($Log -and (Test-Path -LiteralPath $Log -PathType Leaf)) {
            $fullLogPath = [IO.Path]::GetFullPath($Log)
            if (-not $fullLogPath.StartsWith($allowedLogRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $Log = $null
            } else {
                $Log = $fullLogPath
            }
        } else {
            $Log = $null
        }

        $downloads = Join-Path $env:USERPROFILE 'Downloads'
        if (Test-Path -LiteralPath $downloads -PathType Container) {
            $reportDir = Join-Path $downloads 'VIctory-reports'
        } else {
            $reportDir = Join-Path $localRoot 'reports'
        }
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $zipPath = Join-Path $reportDir ("VIctory-report-{0}.zip" -f $stamp)
        $temp = Join-Path ([IO.Path]::GetTempPath()) ("VIctory-report-{0}" -f [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp -Force | Out-Null

        if ($Log) {
            Copy-Item -LiteralPath $Log -Destination (Join-Path $temp 'run.log') -Force
        }

        if (Test-Path -LiteralPath $dataDir -PathType Container) {
            $recent = Get-ChildItem -LiteralPath $dataDir -Filter 'crashes.log' -File -Recurse |
                Where-Object { $_.LastWriteTime -ge (Get-Date).AddHours(-24) }
            if ($recent) {
                $crashText = New-Object System.Text.StringBuilder
                foreach ($crash in $recent) {
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

        if ($env:VICTORY_CACHE_DIR) {
            $cacheDir = $env:VICTORY_CACHE_DIR
        } else {
            $cacheDir = Join-Path $localRoot 'cache'
        }
        $earlyPipelines = Join-Path (Join-Path $cacheDir 'pipelines') 'early-pipelines.txt'
        if (Test-Path -LiteralPath $earlyPipelines -PathType Leaf) {
            Copy-Item -LiteralPath $earlyPipelines -Destination (Join-Path $temp 'early-pipelines.txt') -Force
        }

        $system = New-Object System.Text.StringBuilder
        [void]$system.AppendLine('System report')
        [void]$system.AppendLine('')
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        [void]$system.AppendLine(('Windows: {0}; version {1}; build {2}; {3}' -f $os.Caption, $os.Version, $os.BuildNumber, $os.OSArchitecture))
        $processors = @(Get-CimInstance -ClassName Win32_Processor)
        $cpuNames = @($processors | ForEach-Object { $_.Name } | Where-Object { $_ } | Select-Object -Unique)
        $threadCount = ($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        [void]$system.AppendLine(('CPU: {0}; logical threads: {1}' -f ($cpuNames -join '; '), $threadCount))
        [void]$system.AppendLine(('RAM: {0} MB; commit limit: {1} MB' -f [Math]::Round(($os.TotalVisibleMemorySize / 1024), 0), [Math]::Round(($os.TotalVirtualMemorySize / 1024), 0)))
        [void]$system.AppendLine('')
        [void]$system.AppendLine('Graphics cards:')
        $cards = @(Get-CimInstance -ClassName Win32_VideoController)
        if ($cards.Count -eq 0) { [void]$system.AppendLine('  None reported') }
        foreach ($card in $cards) {
            $memoryMb = if ($card.AdapterRAM) { [Math]::Round(([double]$card.AdapterRAM / 1048576.0), 0) } else { 'unknown' }
            [void]$system.AppendLine(('  {0}; driver {1}; memory {2} MB' -f $card.Name, $card.DriverVersion, $memoryMb))
        }
        $hwsch = 'not present'
        $hwschKey = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        if (Test-Path -LiteralPath $hwschKey) {
            $hwschValue = (Get-ItemProperty -LiteralPath $hwschKey -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
            if ($null -ne $hwschValue) {
                if ([int]$hwschValue -eq 2) { $hwsch = 'on (HwSchMode=2)' }
                elseif ([int]$hwschValue -eq 1) { $hwsch = 'off (HwSchMode=1)' }
                else { $hwsch = ('unknown (HwSchMode={0})' -f $hwschValue) }
            }
        }
        [void]$system.AppendLine(('Hardware-accelerated GPU scheduling: {0}' -f $hwsch))
        $streamlineDll = Join-Path $repo 'nvidia-sdk\Streamline\bin\x64\sl.interposer.dll'
        if (Test-Path -LiteralPath $streamlineDll -PathType Leaf) {
            $dllVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($streamlineDll).FileVersion
            [void]$system.AppendLine(('sl.interposer.dll: present; file version {0}' -f $dllVersion))
        } else {
            [void]$system.AppendLine('sl.interposer.dll: not present')
        }
        $gitCommand = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCommand) {
            $commit = (& $gitCommand.Source -C $repo rev-parse HEAD 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $commit) {
                [void]$system.AppendLine(('Repository commit: {0}' -f $commit))
            } else {
                [void]$system.AppendLine('Repository commit: unavailable')
            }
        } else {
            [void]$system.AppendLine('Repository commit: git not found')
        }
        [IO.File]::WriteAllText((Join-Path $temp 'system.txt'), $system.ToString(), [System.Text.UTF8Encoding]::new($false))

        $summary = New-Object System.Text.StringBuilder
        [void]$summary.AppendLine('Run summary')
        [void]$summary.AppendLine('')
        if ($Log) {
            $bytes = [IO.File]::ReadAllBytes($Log)
            if ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
                $logText = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
            } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {
                $logText = [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
            } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
                $logText = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
            } else {
                $oddNuls = 0
                $evenNuls = 0
                for ($i = 0; $i -lt $bytes.Length; $i++) {
                    if ($bytes[$i] -eq 0) {
                        if (($i % 2) -eq 0) { $evenNuls++ } else { $oddNuls++ }
                    }
                }
                if ($oddNuls -gt $evenNuls) { $logText = [Text.Encoding]::Unicode.GetString($bytes) }
                elseif ($evenNuls -gt $oddNuls) { $logText = [Text.Encoding]::BigEndianUnicode.GetString($bytes) }
                else { $logText = [System.Text.UTF8Encoding]::new($false, $false).GetString($bytes) }
            }
            $escape = [string][char]27
            $cleanLog = [Regex]::Replace($logText, ($escape + '\[[0-?]*[ -/]*[@-~]'), '')
            $fpsValues = New-Object 'System.Collections.Generic.List[double]'
            foreach ($fpsMatch in [Regex]::Matches($cleanLog, '([0-9]+\.[0-9]) fps, [0-9.]+ ms/frame')) {
                $fpsValue = 0.0
                if ([double]::TryParse($fpsMatch.Groups[1].Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$fpsValue)) {
                    $fpsValues.Add($fpsValue)
                }
            }
            if ($fpsValues.Count -gt 0) {
                $lastFps = @($fpsValues | Select-Object -Last 20 | Sort-Object)
                $middle = [int][Math]::Floor($lastFps.Count / 2)
                if (($lastFps.Count % 2) -eq 1) { $median = [double]$lastFps[$middle] }
                else { $median = ([double]$lastFps[$middle - 1] + [double]$lastFps[$middle]) / 2.0 }
                $best = ($fpsValues | Measure-Object -Maximum).Maximum
                [void]$summary.AppendLine(('FPS: median of last {0}: {1}; best: {2}' -f $lastFps.Count, $median.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture), ([double]$best).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)))
            } else {
                [void]$summary.AppendLine('FPS: no matching samples')
            }
            $budgetMatches = [Regex]::Matches($cleanLog, 'vram_budget_mb=(\d+)')
            if ($budgetMatches.Count -gt 0) {
                [void]$summary.AppendLine(('Card memory budget: {0} MB' -f $budgetMatches[$budgetMatches.Count - 1].Groups[1].Value))
            } else {
                [void]$summary.AppendLine('Card memory budget: not found')
            }
            $textureMatches = [Regex]::Matches($cleanLog, 'picked by index: \d+ uploaded so far \([0-9.]+ MB\), (\d+) waiting')
            if ($textureMatches.Count -gt 0) {
                [void]$summary.AppendLine(('Textures waiting at end: {0}' -f $textureMatches[$textureMatches.Count - 1].Groups[1].Value))
            } else {
                [void]$summary.AppendLine('Textures waiting at end: not found')
            }
            $drawMatches = [Regex]::Matches($cleanLog, 'dropped (\d+) without a host pipeline \((\d+) being made')
            if ($drawMatches.Count -gt 0) {
                $lastDraw = $drawMatches[$drawMatches.Count - 1]
                [void]$summary.AppendLine(('Draws dropped at end: {0}; host pipelines being made: {1}' -f $lastDraw.Groups[1].Value, $lastDraw.Groups[2].Value))
            } else {
                [void]$summary.AppendLine('Draws dropped at end: not found')
            }
            $reasonValues = @{}
            foreach ($reasonMatch in [Regex]::Matches($cleanLog, 'dropped ([0-9.]+)/frame without a host pipeline: (.+)')) {
                $rate = 0.0
                if ([double]::TryParse($reasonMatch.Groups[1].Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$rate)) {
                    $reasonValues[$reasonMatch.Groups[2].Value.Trim()] = $rate
                }
            }
            [void]$summary.AppendLine('Reasons (last value per reason, top 6):')
            $topReasons = @($reasonValues.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6)
            if ($topReasons.Count -eq 0) { [void]$summary.AppendLine('  None found') }
            foreach ($reason in $topReasons) {
                [void]$summary.AppendLine(('  {0}: {1}/frame' -f $reason.Key, ([double]$reason.Value).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)))
            }
            [void]$summary.AppendLine('')
            [void]$summary.AppendLine('Log message counts:')
            $countPatterns = [ordered]@{
                'shader does not translate' = 'shader does not translate'
                'host pipeline refused' = 'host pipeline refused'
                'slow host submission' = 'slow host submission'
                'device removed / DEVICE_REMOVED / DEVICE_HUNG' = 'device removed|DEVICE_REMOVED|DEVICE_HUNG'
                'out of memory / E_OUTOFMEMORY / 0x8007000e' = 'out of memory|E_OUTOFMEMORY|0x8007000e'
            }
            foreach ($label in $countPatterns.Keys) {
                $count = [Regex]::Matches($cleanLog, $countPatterns[$label], [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
                [void]$summary.AppendLine(('  {0}: {1}' -f $label, $count))
            }
        } else {
            [void]$summary.AppendLine('Run log: not found in the foxhound logs folder')
        }
        $summaryText = $summary.ToString()
        [IO.File]::WriteAllText((Join-Path $temp 'summary.txt'), $summaryText, [System.Text.UTF8Encoding]::new($false))

        Compress-Archive -Path (Join-Path $temp '*') -DestinationPath $zipPath -Force
        Write-Host $summaryText
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
