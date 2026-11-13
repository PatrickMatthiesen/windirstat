[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BaselineExePath,
    [Parameter(Mandatory)] [string] $CandidateExePath,
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
$BaselineExePath = (Resolve-Path -LiteralPath $BaselineExePath).Path
$CandidateExePath = (Resolve-Path -LiteralPath $CandidateExePath).Path
$ScanRoot = (Resolve-Path -LiteralPath $ScanRoot).Path
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $PSScriptRoot ('results\compare-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "Refusing to overwrite existing comparison output: $OutputDirectory"
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null

function Get-Distribution {
    param([Parameter(Mandatory)] [double[]] $Values)

    if ($Values.Count -eq 0) { throw 'Cannot summarize an empty measurement set.' }
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

function New-Runner {
    param(
        [Parameter(Mandatory)] [string] $Parent,
        [Parameter(Mandatory)] [string] $IniContent
    )

    $root = Join-Path $Parent 'runner'
    New-Item -ItemType Directory -Path $root | Out-Null
    $runnerExe = Join-Path $root 'WinDirStat.exe'
    [IO.File]::WriteAllText((Join-Path $root 'WinDirStat.ini'), $IniContent, [Text.Encoding]::Unicode)
    [pscustomobject] @{ Root = $root; Exe = $runnerExe }
}

function Invoke-BenchmarkRun {
    param(
        [Parameter(Mandatory)] [pscustomobject] $Runner,
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $Executable,
        [Parameter(Mandatory)] [string] $ReportPath,
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [int] $Timeout
    )

    # Both builds execute from the same path to avoid path-specific Defender,
    # reputation, and file-cache bias between baseline and candidate.
    Copy-Item -LiteralPath $Executable -Destination $Runner.Exe -Force

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Runner.Exe
    $startInfo.WorkingDirectory = $Runner.Root
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    [void] $startInfo.ArgumentList.Add('/perfreport')
    [void] $startInfo.ArgumentList.Add($ReportPath)
    [void] $startInfo.ArgumentList.Add($Root)

    $process = [Diagnostics.Process]::Start($startInfo)
    if (-not $process.WaitForExit($Timeout * 1000)) {
        try { $process.Kill($true) } catch {}
        throw "$Label benchmark timed out after $Timeout seconds."
    }
    if ($process.ExitCode -ne 0) {
        throw "$Label benchmark exited with code $($process.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $ReportPath)) {
        throw "$Label benchmark did not create $ReportPath."
    }

    $report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
    if ($report.schema_version -ne 1 -or $null -eq $report.wall_ms.total_settled) {
        throw "$Label report does not match performance schema version 1."
    }
    return $report
}

function Get-Inventory {
    param([Parameter(Mandatory)] [pscustomobject] $Report)

    [ordered] @{
        files = [uint64] $Report.result.files
        folders = [uint64] $Report.result.folders
        logical_bytes = [uint64] $Report.result.logical_bytes
        physical_bytes = [uint64] $Report.result.physical_bytes
        fast_scan_used = [bool] $Report.engine.fast_scan_used
    }
}

function Assert-InventoryEqual {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Expected,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Actual,
        [Parameter(Mandatory)] [string] $Context
    )

    foreach ($field in @('files', 'folders', 'logical_bytes', 'physical_bytes', 'fast_scan_used')) {
        if ($Expected[$field] -ne $Actual[$field]) {
            throw "Inventory mismatch for $Context field '$field': baseline=$($Expected[$field]), actual=$($Actual[$field])."
        }
    }
}

function Get-BuildStatistics {
    param([Parameter(Mandatory)] [object[]] $Rows)

    [ordered] @{
        total_settled_ms = Get-Distribution @($Rows.total_settled_ms)
        enumeration_and_materialization_ms = Get-Distribution @($Rows.enumeration_and_materialization_ms)
        mft_parse_and_index_work_ms = Get-Distribution @($Rows.mft_parse_and_index_work_ms)
        user_cpu_ms = Get-Distribution @($Rows.user_cpu_ms)
        peak_working_set_bytes = Get-Distribution @($Rows.peak_working_set_bytes)
    }
}

function Get-Comparison {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Baseline,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Candidate
    )

    $result = [ordered] @{}
    foreach ($metric in $Baseline.Keys) {
        $baselineMedian = [double] $Baseline[$metric].median
        $candidateMedian = [double] $Candidate[$metric].median
        $result[$metric] = [ordered] @{
            baseline_median = $baselineMedian
            candidate_median = $candidateMedian
            percent_change = if ($baselineMedian -eq 0) { $null } else {
                [math]::Round((($candidateMedian - $baselineMedian) / $baselineMedian) * 100, 3)
            }
            baseline_over_candidate = if ($candidateMedian -eq 0) { $null } else {
                [math]::Round($baselineMedian / $candidateMedian, 4)
            }
        }
    }
    return $result
}

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

$runnerRoot = Join-Path ([IO.Path]::GetTempPath()) ('windirstat-comparison-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runnerRoot | Out-Null
$runner = New-Runner $runnerRoot $ini
$executables = @{ baseline = $BaselineExePath; candidate = $CandidateExePath }
$measurements = [Collections.Generic.List[object]]::new()
$baselineInventory = $null
$baselineCommit = $null
$candidateCommit = $null
$runIndex = 0
$totalRuns = 2 * ($Warmups + $Iterations)

try {
    for ($warmup = 1; $warmup -le $Warmups; ++$warmup) {
        $order = if (($warmup % 2) -eq 1) { @('baseline', 'candidate') } else { @('candidate', 'baseline') }
        foreach ($label in $order) {
            ++$runIndex
            Write-Host "[$runIndex/$totalRuns] warmup $warmup $label"
            $reportPath = Join-Path $OutputDirectory ('{0}-warmup-{1:d2}.json' -f $label, $warmup)
            [void] (Invoke-BenchmarkRun $runner $label $executables[$label] $reportPath $ScanRoot $TimeoutSeconds)
        }
    }

    for ($iteration = 1; $iteration -le $Iterations; ++$iteration) {
        $order = if (($iteration % 2) -eq 1) { @('baseline', 'candidate') } else { @('candidate', 'baseline') }
        $pairInventories = @{}
        foreach ($label in $order) {
            ++$runIndex
            Write-Host "[$runIndex/$totalRuns] measurement $iteration $label"
            $reportPath = Join-Path $OutputDirectory ('{0}-measurement-{1:d2}.json' -f $label, $iteration)
            $report = Invoke-BenchmarkRun $runner $label $executables[$label] $reportPath $ScanRoot $TimeoutSeconds
            $inventory = Get-Inventory $report
            $pairInventories[$label] = $inventory

            if ($null -eq $baselineInventory -and $label -eq 'baseline') {
                $baselineInventory = $inventory
            } elseif ($null -ne $baselineInventory) {
                Assert-InventoryEqual $baselineInventory $inventory "$label iteration $iteration"
            }

            if ($label -eq 'baseline' -and $null -eq $baselineCommit) { $baselineCommit = [string] $report.build.commit }
            if ($label -eq 'candidate' -and $null -eq $candidateCommit) { $candidateCommit = [string] $report.build.commit }

            $measurements.Add([pscustomobject] @{
                iteration = $iteration
                order_in_pair = [array]::IndexOf($order, $label) + 1
                build = $label
                report = [IO.Path]::GetFileName($reportPath)
                total_settled_ms = [double] $report.wall_ms.total_settled
                enumeration_and_materialization_ms = [double] $report.wall_ms.enumeration_and_materialization
                mft_parse_and_index_work_ms = [double] $report.parallel_work_ms.mft_parse_and_index
                user_cpu_ms = [double] $report.process.user_cpu_ms
                peak_working_set_bytes = [uint64] $report.process.process_peak_working_set_bytes
                files = [uint64] $report.result.files
                folders = [uint64] $report.result.folders
                logical_bytes = [uint64] $report.result.logical_bytes
                physical_bytes = [uint64] $report.result.physical_bytes
                fast_scan_used = [bool] $report.engine.fast_scan_used
            })
        }
        Assert-InventoryEqual $pairInventories.baseline $pairInventories.candidate "paired iteration $iteration"
    }
}
finally {
    if (Test-Path -LiteralPath $runnerRoot) {
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedRunner = [IO.Path]::GetFullPath($runnerRoot).TrimEnd('\') + '\'
        if (-not $resolvedRunner.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($runnerRoot) -notlike 'windirstat-comparison-*') {
            throw "Refusing to remove unexpected runner path: $runnerRoot"
        }
        Remove-Item -LiteralPath $runnerRoot -Recurse -Force
    }
}

$baselineRows = @($measurements | Where-Object build -eq 'baseline')
$candidateRows = @($measurements | Where-Object build -eq 'candidate')
$baselineStatistics = Get-BuildStatistics $baselineRows
$candidateStatistics = Get-BuildStatistics $candidateRows
$comparison = Get-Comparison $baselineStatistics $candidateStatistics
$pairedMeasurements = for ($iteration = 1; $iteration -le $Iterations; ++$iteration) {
    $baselineRow = $baselineRows | Where-Object iteration -eq $iteration | Select-Object -First 1
    $candidateRow = $candidateRows | Where-Object iteration -eq $iteration | Select-Object -First 1
    [pscustomobject] @{
        iteration = $iteration
        baseline_first = $baselineRow.order_in_pair -eq 1
        baseline_total_settled_ms = $baselineRow.total_settled_ms
        candidate_total_settled_ms = $candidateRow.total_settled_ms
        total_settled_percent_change = [math]::Round(
            (($candidateRow.total_settled_ms - $baselineRow.total_settled_ms) / $baselineRow.total_settled_ms) * 100, 3)
        baseline_over_candidate = [math]::Round(
            $baselineRow.total_settled_ms / $candidateRow.total_settled_ms, 4)
    }
}
$pairedStatistics = [ordered] @{
    total_settled_percent_change = Get-Distribution @($pairedMeasurements.total_settled_percent_change)
    baseline_over_candidate = Get-Distribution @($pairedMeasurements.baseline_over_candidate)
}
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$os = Get-CimInstance Win32_OperatingSystem
$defender = try {
    $status = Get-MpComputerStatus
    [ordered] @{ real_time_protection_enabled = [bool] $status.RealTimeProtectionEnabled }
} catch {
    [ordered] @{ real_time_protection_enabled = $null }
}

$baselineHash = (Get-FileHash -LiteralPath $BaselineExePath -Algorithm SHA256).Hash.ToLowerInvariant()
$candidateHash = (Get-FileHash -LiteralPath $CandidateExePath -Algorithm SHA256).Hash.ToLowerInvariant()
$summary = [ordered] @{
    schema_version = 1
    generated_utc = [DateTime]::UtcNow.ToString('o')
    inventory_match = $true
    binaries = [ordered] @{
        baseline = [ordered] @{ path = $BaselineExePath; sha256 = $baselineHash; build_commit = $baselineCommit }
        candidate = [ordered] @{ path = $CandidateExePath; sha256 = $candidateHash; build_commit = $candidateCommit }
        identical_sha256 = $baselineHash -eq $candidateHash
    }
    scan_root = $ScanRoot
    settings = [ordered] @{
        iterations = $Iterations
        warmups_per_build = $Warmups
        execution_order = 'paired-alternating'
        threads = $Threads
        fast_scan_requested = $FastScan
        hardlinks_enabled = $ProcessHardlinks
        cache_state = 'warm-or-uncontrolled'
    }
    inventory = $baselineInventory
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
    statistics = [ordered] @{ baseline = $baselineStatistics; candidate = $candidateStatistics }
    comparison = $comparison
    paired_statistics = $pairedStatistics
    paired_measurements = @($pairedMeasurements)
    measurements = @($measurements)
}

$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'comparison.json') -Encoding utf8
$measurements | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'measurements.csv') -NoTypeInformation -Encoding utf8
$pairedMeasurements | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'paired-measurements.csv') -NoTypeInformation -Encoding utf8

[pscustomobject] @{
    Metric = 'total_settled_ms'
    BaselineMedian = $comparison.total_settled_ms.baseline_median
    CandidateMedian = $comparison.total_settled_ms.candidate_median
    PercentChange = $comparison.total_settled_ms.percent_change
    MedianPairedChange = $pairedStatistics.total_settled_percent_change.median
    BaselineOverCandidate = $comparison.total_settled_ms.baseline_over_candidate
} | Format-Table -AutoSize
Write-Host "Inventory match: true"
Write-Host "Results: $OutputDirectory"
