# WinDirStat scan benchmarks

Phase 0 adds an opt-in, quiet performance report and a repeatable local runner.
Normal interactive scans do not collect telemetry.

Build an x64 Release executable, then run:

```powershell
pwsh ./benchmarks/Invoke-ScanBenchmark.ps1 `
    -ExePath ./build/WinDirStat_x64.exe `
    -ScanRoot D:\benchmark-fixture `
    -Warmups 1 `
    -Iterations 5 `
    -Threads 4
```

The runner stages a portable copy of WinDirStat, performs warmups followed by
measured runs, and writes each raw report plus `summary.json` and
`measurements.csv`. The summary reports median, minimum, maximum, and median
absolute deviation. Runs are currently labelled `warm-or-uncontrolled`; cold-cache
testing requires an explicitly controlled environment.

The executable contract is:

```text
WinDirStat.exe /perfreport <report.json> <scan-root>
```

`/perfreport` is a standalone operation and cannot be combined with `/saveto`,
`/savedupesto`, `/savepermsto`, or `/loadfrom`. The report contains no scan path.
It separates wall-clock phases from summed parallel worker time so overlapping MFT
read and parse work is not misrepresented as end-to-end elapsed time.

This is the first Phase 0 slice. Generated NTFS VHDX fixtures, cold-cache control,
inventory parity automation, allocation/ETW capture, and focused parser
microbenchmarks remain follow-up work described in `PERFORMANCE_PLAN.md`.
