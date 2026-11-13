[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ExePath,
    [Parameter(Mandatory)] [string] $ScanRoot,
    [string] $OutputDirectory,
    [ValidateRange(1, 100)] [int] $Iterations = 5,
    [ValidateRange(0, 20)] [int] $Warmups = 1,
    [ValidateRange(1, 16)] [int] $Threads = 4,
    [bool] $FastScan = $true,
    [bool] $ProcessHardlinks = $true,
    [ValidateRange(1, 7200)] [int] $TimeoutSeconds = 1800
)

$ErrorActionPreference = 'Stop'
$ExePath = (Resolve-Path -LiteralPath $ExePath).Path
$ScanRoot = (Resolve-Path -LiteralPath $ScanRoot).Path
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $PSScriptRoot ('results\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Get-Distribution {
    param([double[]] $Values)

    $sorted = @($Values | Sort-Object)
    $middle = [int] [math]::Floor($sorted.Count / 2)
    $median = if (($sorted.Count % 2) -eq 0) {
        ($sorted[$middle - 1] + $sorted[$middle]) / 2
    } else {
        $sorted[$middle]
    }
    $deviations = @($Values | ForEach-Object { [math]::Abs($_ - $median) } | Sort-Object)
    $mad = if (($deviations.Count % 2) -eq 0) {
        ($deviations[$middle - 1] + $deviations[$middle]) / 2
    } else {
        $deviations[$middle]
    }

    [ordered] @{
        median = [math]::Round($median, 3)
        minimum = [math]::Round($sorted[0], 3)
        maximum = [math]::Round($sorted[-1], 3)
        median_absolute_deviation = [math]::Round($mad, 3)
    }
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$runnerRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('windirstat-benchmark-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runnerRoot | Out-Null
$runnerExe = Join-Path $runnerRoot 'WinDirStat.exe'
Copy-Item -LiteralPath $ExePath -Destination $runnerExe

$ini = @(
    '[Options]'
    'LanguageId=9'
    "UseFastScanEngine=$([int] $FastScan)"
    "ScanningThreads=$Threads"
    'UseBackupRestore=0'
    'ShowElevationPrompt=0'
    'AutoElevate=0'
    'ShowFreeSpace=0'
    'ShowUnknown=0'
    "ProcessHardlinks=$([int] $ProcessHardlinks)"
    '[DupeView]'
    'ScanForDuplicates=0'
) -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $runnerRoot 'WinDirStat.ini'), $ini,
    [System.Text.Encoding]::Unicode)

$measurements = [System.Collections.Generic.List[object]]::new()
try {
    $totalRuns = $Warmups + $Iterations
    for ($index = 0; $index -lt $totalRuns; ++$index) {
        $isWarmup = $index -lt $Warmups
        $ordinal = if ($isWarmup) { $index + 1 } else { $index - $Warmups + 1 }
        $kind = if ($isWarmup) { 'warmup' } else { 'measurement' }
        $reportPath = Join-Path $OutputDirectory ('{0}-{1:d2}.json' -f $kind, $ordinal)

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $runnerExe
        $startInfo.WorkingDirectory = $runnerRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        [void] $startInfo.ArgumentList.Add('/perfreport')
        [void] $startInfo.ArgumentList.Add($reportPath)
        [void] $startInfo.ArgumentList.Add($ScanRoot)

        Write-Host ('[{0}/{1}] {2} {3}' -f ($index + 1), $totalRuns, $kind, $ScanRoot)
        $process = [Diagnostics.Process]::Start($startInfo)
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch {}
            throw "Benchmark run timed out after $TimeoutSeconds seconds."
        }
        if ($process.ExitCode -ne 0) {
            throw "Benchmark run exited with code $($process.ExitCode)."
        }
        if (-not (Test-Path -LiteralPath $reportPath)) {
            throw "Benchmark run did not create $reportPath."
        }

        $report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
        if ($report.schema_version -ne 1 -or $null -eq $report.wall_ms.total_settled) {
            throw "Benchmark report $reportPath does not match schema version 1."
        }
        if (-not $isWarmup) {
            $measurements.Add([pscustomobject] @{
                iteration = $ordinal
                report = [System.IO.Path]::GetFileName($reportPath)
                total_settled_ms = [double] $report.wall_ms.total_settled
                enumeration_and_materialization_ms = [double] $report.wall_ms.enumeration_and_materialization
                mft_parse_and_index_work_ms = [double] $report.parallel_work_ms.mft_parse_and_index
                user_cpu_ms = [double] $report.process.user_cpu_ms
                peak_working_set_bytes = [uint64] $report.process.process_peak_working_set_bytes
                files = [uint64] $report.result.files
                folders = [uint64] $report.result.folders
                fast_scan_used = [bool] $report.engine.fast_scan_used
            })
        }
    }
}
finally {
    if (Test-Path -LiteralPath $runnerRoot) {
        Remove-Item -LiteralPath $runnerRoot -Recurse -Force
    }
}

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$os = Get-CimInstance Win32_OperatingSystem
$defender = try {
    $status = Get-MpComputerStatus
    [ordered] @{ real_time_protection_enabled = [bool] $status.RealTimeProtectionEnabled }
} catch {
    [ordered] @{ real_time_protection_enabled = $null }
}

$summary = [ordered] @{
    schema_version = 1
    generated_utc = [DateTime]::UtcNow.ToString('o')
    executable = $ExePath
    scan_root = $ScanRoot
    settings = [ordered] @{
        iterations = $Iterations
        warmups = $Warmups
        threads = $Threads
        fast_scan_requested = $FastScan
        hardlinks_enabled = $ProcessHardlinks
        cache_state = 'warm-or-uncontrolled'
    }
    host = [ordered] @{
        computer_name = $env:COMPUTERNAME
        cpu = $cpu.Name
        logical_processors = $cpu.NumberOfLogicalProcessors
        windows_caption = $os.Caption
        windows_version = $os.Version
        windows_build = $os.BuildNumber
        elevated = Test-IsElevated
        defender = $defender
    }
    statistics = [ordered] @{
        total_settled_ms = Get-Distribution @($measurements.total_settled_ms)
        enumeration_and_materialization_ms = Get-Distribution @($measurements.enumeration_and_materialization_ms)
        user_cpu_ms = Get-Distribution @($measurements.user_cpu_ms)
        peak_working_set_bytes = Get-Distribution @($measurements.peak_working_set_bytes)
    }
    measurements = @($measurements)
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding utf8
$measurements | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'measurements.csv') -NoTypeInformation -Encoding utf8
$summary.statistics | Format-List
Write-Host "Results: $OutputDirectory"
