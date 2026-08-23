[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $DefinitionPath,
    [Parameter(Mandatory)] [string] $VhdxPath,
    [switch] $PlanOnly,
    [switch] $KeepMounted
)

$ErrorActionPreference = 'Stop'

function Assert-Count {
    param([object] $Value, [string] $Name, [int64] $Minimum = 0)
    if ($null -eq $Value -or [int64] $Value -lt $Minimum) {
        throw "Fixture property '$Name' must be an integer greater than or equal to $Minimum."
    }
}

function Get-FreeDriveLetter {
    $used = @([IO.DriveInfo]::GetDrives().Name | ForEach-Object { $_[0].ToString().ToUpperInvariant() })
    foreach ($letter in [char[]] 'ZYXWVUTSRQPONMLKJIHGFED') {
        if ($letter.ToString() -notin $used) { return $letter.ToString() }
    }
    throw 'No free drive letter is available for mounting the benchmark VHDX.'
}

function Invoke-DiskPartScript {
    param([Parameter(Mandatory)] [string[]] $Commands)

    $scriptPath = Join-Path ([IO.Path]::GetTempPath()) ('windirstat-diskpart-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        [IO.File]::WriteAllLines($scriptPath, $Commands, [Text.Encoding]::ASCII)
        $output = & diskpart.exe /s $scriptPath 2>&1
        if ($LASTEXITCODE -ne 0 -or $output -match 'encountered an error|Virtual Disk Service error') {
            throw "diskpart failed with exit code $LASTEXITCODE.`n$($output -join [Environment]::NewLine)"
        }
        return $output
    }
    finally {
        if (Test-Path -LiteralPath $scriptPath) {
            Remove-Item -LiteralPath $scriptPath -Force
        }
    }
}

function New-DeterministicFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [int64] $Length,
        [byte] $Seed = 0
    )

    $buffer = [byte[]]::new([math]::Min([int64] 65536, [math]::Max([int64] 1, $Length)))
    for ($index = 0; $index -lt $buffer.Length; ++$index) {
        $buffer[$index] = [byte] (($Seed + $index) % 251)
    }
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::None, 65536, [IO.FileOptions]::SequentialScan)
    try {
        $remaining = $Length
        while ($remaining -gt 0) {
            $count = [int] [math]::Min($remaining, $buffer.Length)
            $stream.Write($buffer, 0, $count)
            $remaining -= $count
        }
    }
    finally {
        $stream.Dispose()
    }
}

$DefinitionPath = (Resolve-Path -LiteralPath $DefinitionPath).Path
$definition = Get-Content -Raw -LiteralPath $DefinitionPath | ConvertFrom-Json
if ($definition.schema_version -ne 1) { throw 'Only fixture schema version 1 is supported.' }
if ([string]::IsNullOrWhiteSpace($definition.name)) { throw "Fixture property 'name' is required." }
if ($definition.volume_label -notmatch '^[A-Za-z0-9_-]{1,32}$') {
    throw "Fixture property 'volume_label' must contain 1-32 safe label characters."
}
Assert-Count $definition.vhdx_maximum_size_mb 'vhdx_maximum_size_mb' 64
Assert-Count $definition.allocation_unit_bytes 'allocation_unit_bytes' 512

$layout = $definition.layout
Assert-Count $layout.mixed.file_count 'layout.mixed.file_count'
Assert-Count $layout.mixed.directory_count 'layout.mixed.directory_count' 1
Assert-Count $layout.mixed.minimum_size 'layout.mixed.minimum_size'
Assert-Count $layout.mixed.maximum_size 'layout.mixed.maximum_size'
if ([int64] $layout.mixed.maximum_size -lt [int64] $layout.mixed.minimum_size) {
    throw 'layout.mixed.maximum_size must be greater than or equal to minimum_size.'
}
Assert-Count $layout.wide.file_count 'layout.wide.file_count'
Assert-Count $layout.wide.file_size 'layout.wide.file_size'
Assert-Count $layout.deep.depth 'layout.deep.depth'
Assert-Count $layout.deep.file_size 'layout.deep.file_size'
Assert-Count $layout.hardlinks.additional_links 'layout.hardlinks.additional_links'
Assert-Count $layout.hardlinks.file_size 'layout.hardlinks.file_size'
Assert-Count $layout.resident.file_count 'layout.resident.file_count'
Assert-Count $layout.resident.file_size 'layout.resident.file_size'
Assert-Count $layout.sparse.file_count 'layout.sparse.file_count'
Assert-Count $layout.sparse.logical_size 'layout.sparse.logical_size'
Assert-Count $layout.compressed.file_count 'layout.compressed.file_count'
Assert-Count $layout.compressed.logical_size 'layout.compressed.logical_size'
Assert-Count $layout.wof.file_count 'layout.wof.file_count'
Assert-Count $layout.wof.logical_size 'layout.wof.logical_size'
Assert-Count $layout.reparse.junction_count 'layout.reparse.junction_count'
Assert-Count $layout.reparse.symlink_count 'layout.reparse.symlink_count'
Assert-Count $layout.mft_churn_records 'layout.mft_churn_records'

$VhdxPath = [IO.Path]::GetFullPath($VhdxPath)
if ([IO.Path]::GetExtension($VhdxPath) -ne '.vhdx') { throw 'VhdxPath must end in .vhdx.' }
if ($VhdxPath.IndexOfAny([char[]] "`r`n`"") -ge 0) { throw 'VhdxPath contains unsupported characters.' }
$vhdxParent = Split-Path -Parent $VhdxPath
if (-not (Test-Path -LiteralPath $vhdxParent -PathType Container)) {
    throw "The VHDX parent directory does not exist: $vhdxParent"
}
if (Test-Path -LiteralPath $VhdxPath) {
    throw "Refusing to overwrite existing VHDX: $VhdxPath"
}
$manifestPath = $VhdxPath + '.manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    throw "Refusing to overwrite existing fixture manifest: $manifestPath"
}

$expectedLiveFiles =
    [int64] $layout.mixed.file_count +
    [int64] $layout.wide.file_count +
    [int64] $layout.deep.depth +
    1 + [int64] $layout.hardlinks.additional_links +
    [int64] $layout.resident.file_count +
    [int64] $layout.sparse.file_count +
    [int64] $layout.compressed.file_count +
    [int64] $layout.wof.file_count

$definitionHash = (Get-FileHash -LiteralPath $DefinitionPath -Algorithm SHA256).Hash.ToLowerInvariant()
$plan = [ordered] @{
    schema_version = 1
    definition = $DefinitionPath
    definition_sha256 = $definitionHash
    fixture_name = [string] $definition.name
    vhdx_path = $VhdxPath
    vhdx_maximum_size_mb = [int64] $definition.vhdx_maximum_size_mb
    volume_label = [string] $definition.volume_label
    expected_live_files = $expectedLiveFiles
    mft_churn_records = [int64] $layout.mft_churn_records
    keep_mounted = [bool] $KeepMounted
}
if ($PlanOnly) {
    $plan | ConvertTo-Json -Depth 5
    return
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Creating and formatting a benchmark VHDX requires an elevated PowerShell session.'
}
if (-not $PSCmdlet.ShouldProcess($VhdxPath, "Create, attach, and format disposable NTFS benchmark VHDX '$($definition.name)'")) {
    return
}

$driveLetter = Get-FreeDriveLetter
$driveRoot = "$driveLetter`:\"
$attached = $false
$completed = $false
$generated = [ordered] @{}
try {
    Invoke-DiskPartScript @(
        "create vdisk file=`"$VhdxPath`" maximum=$([int64] $definition.vhdx_maximum_size_mb) type=expandable"
        "select vdisk file=`"$VhdxPath`""
        'attach vdisk'
        'create partition primary'
        "format fs=ntfs quick label=`"$($definition.volume_label)`" unit=$([int64] $definition.allocation_unit_bytes)"
        "assign letter=$driveLetter"
    ) | Out-Null
    $attached = $true
    if (-not (Test-Path -LiteralPath $driveRoot -PathType Container)) {
        throw "The VHDX was attached but $driveRoot is not accessible."
    }

    $fixtureRoot = Join-Path $driveRoot 'fixture'
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null

    $mixedRoot = Join-Path $fixtureRoot 'mixed'
    New-Item -ItemType Directory -Path $mixedRoot | Out-Null
    $mixedDirectories = for ($index = 0; $index -lt [int] $layout.mixed.directory_count; ++$index) {
        $directory = Join-Path $mixedRoot ('d-{0:d6}' -f $index)
        New-Item -ItemType Directory -Path $directory | Out-Null
        $directory
    }
    $sizeSpan = [int64] $layout.mixed.maximum_size - [int64] $layout.mixed.minimum_size + 1
    for ($index = 0; $index -lt [int64] $layout.mixed.file_count; ++$index) {
        $directory = $mixedDirectories[$index % $mixedDirectories.Count]
        $length = [int64] $layout.mixed.minimum_size + ($index % $sizeSpan)
        New-DeterministicFile (Join-Path $directory ('f-{0:d8}.bin' -f $index)) $length ([byte] ($index % 251))
    }
    $generated.mixed_files = [int64] $layout.mixed.file_count

    $wideRoot = Join-Path $fixtureRoot 'wide'
    New-Item -ItemType Directory -Path $wideRoot | Out-Null
    for ($index = 0; $index -lt [int64] $layout.wide.file_count; ++$index) {
        New-DeterministicFile (Join-Path $wideRoot ('w-{0:d8}.bin' -f $index)) ([int64] $layout.wide.file_size) ([byte] ($index % 251))
    }
    $generated.wide_files = [int64] $layout.wide.file_count

    $deepRoot = Join-Path $fixtureRoot 'deep'
    New-Item -ItemType Directory -Path $deepRoot | Out-Null
    $deepCurrent = $deepRoot
    for ($index = 0; $index -lt [int] $layout.deep.depth; ++$index) {
        $deepCurrent = Join-Path $deepCurrent ('d{0:d3}' -f $index)
        New-Item -ItemType Directory -Path $deepCurrent | Out-Null
        New-DeterministicFile (Join-Path $deepCurrent 'entry.bin') ([int64] $layout.deep.file_size) ([byte] ($index % 251))
    }
    $generated.deep_files = [int64] $layout.deep.depth

    $hardlinkRoot = Join-Path $fixtureRoot 'hardlinks'
    New-Item -ItemType Directory -Path $hardlinkRoot | Out-Null
    $hardlinkSeed = Join-Path $hardlinkRoot 'seed.bin'
    New-DeterministicFile $hardlinkSeed ([int64] $layout.hardlinks.file_size) 71
    for ($index = 0; $index -lt [int] $layout.hardlinks.additional_links; ++$index) {
        $hardlinkPath = Join-Path $hardlinkRoot ('link-{0:d6}.bin' -f $index)
        & fsutil.exe hardlink create $hardlinkPath $hardlinkSeed | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "fsutil failed to create hardlink: $hardlinkPath" }
    }
    $generated.hardlink_names = 1 + [int64] $layout.hardlinks.additional_links

    $residentRoot = Join-Path $fixtureRoot 'resident'
    New-Item -ItemType Directory -Path $residentRoot | Out-Null
    for ($index = 0; $index -lt [int] $layout.resident.file_count; ++$index) {
        New-DeterministicFile (Join-Path $residentRoot ('resident-{0:d6}.bin' -f $index)) ([int64] $layout.resident.file_size) ([byte] ($index % 251))
    }
    $generated.resident_files = [int64] $layout.resident.file_count

    $sparseRoot = Join-Path $fixtureRoot 'sparse'
    New-Item -ItemType Directory -Path $sparseRoot | Out-Null
    for ($index = 0; $index -lt [int] $layout.sparse.file_count; ++$index) {
        $path = Join-Path $sparseRoot ('sparse-{0:d4}.bin' -f $index)
        $stream = [IO.File]::Create($path)
        try { $stream.SetLength([int64] $layout.sparse.logical_size) } finally { $stream.Dispose() }
        & fsutil.exe sparse setflag $path | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "fsutil failed to mark sparse file: $path" }
    }
    $generated.sparse_files = [int64] $layout.sparse.file_count

    foreach ($kind in @('compressed', 'wof')) {
        $root = Join-Path $fixtureRoot $kind
        New-Item -ItemType Directory -Path $root | Out-Null
        $entry = $layout.$kind
        for ($index = 0; $index -lt [int] $entry.file_count; ++$index) {
            $path = Join-Path $root ("$kind-{0:d4}.bin" -f $index)
            New-DeterministicFile $path ([int64] $entry.logical_size) 17
            $arguments = if ($kind -eq 'wof') { @('/C', '/I', '/Q', '/EXE:LZX', $path) } else { @('/C', '/I', '/Q', $path) }
            & compact.exe @arguments | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "compact failed for ${kind} file: $path" }
        }
        $generated["${kind}_files"] = [int64] $entry.file_count
    }

    $reparseRoot = Join-Path $fixtureRoot 'reparse'
    $reparseTarget = Join-Path $fixtureRoot 'reparse-target'
    New-Item -ItemType Directory -Path $reparseRoot, $reparseTarget | Out-Null
    for ($index = 0; $index -lt [int] $layout.reparse.junction_count; ++$index) {
        New-Item -ItemType Junction -Path (Join-Path $reparseRoot ('junction-{0:d4}' -f $index)) -Target $reparseTarget | Out-Null
    }
    for ($index = 0; $index -lt [int] $layout.reparse.symlink_count; ++$index) {
        New-Item -ItemType SymbolicLink -Path (Join-Path $reparseRoot ('symlink-{0:d4}' -f $index)) -Target $reparseTarget | Out-Null
    }
    $generated.reparse_directories = [int64] $layout.reparse.junction_count + [int64] $layout.reparse.symlink_count

    $churnRoot = Join-Path $fixtureRoot 'mft-churn'
    New-Item -ItemType Directory -Path $churnRoot | Out-Null
    for ($index = 0; $index -lt [int64] $layout.mft_churn_records; ++$index) {
        New-DeterministicFile (Join-Path $churnRoot ('deleted-{0:d8}.tmp' -f $index)) 0
    }
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\') + '\'
    $resolvedChurnRoot = [IO.Path]::GetFullPath($churnRoot).TrimEnd('\') + '\'
    if (-not $resolvedChurnRoot.StartsWith($resolvedFixtureRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove churn data outside the fixture root: $resolvedChurnRoot"
    }
    Remove-Item -LiteralPath $churnRoot -Recurse -Force
    $generated.deleted_mft_records_requested = [int64] $layout.mft_churn_records

    $manifest = [ordered] @{
        schema_version = 1
        generated_utc = [DateTime]::UtcNow.ToString('o')
        fixture_name = [string] $definition.name
        definition_sha256 = $definitionHash
        vhdx_file = [IO.Path]::GetFileName($VhdxPath)
        volume = [ordered] @{
            filesystem = 'NTFS'
            label = [string] $definition.volume_label
            allocation_unit_bytes = [int64] $definition.allocation_unit_bytes
        }
        expected_live_files = $expectedLiveFiles
        generated = $generated
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    $completed = $true
    Write-Host "Created fixture: $VhdxPath"
    Write-Host "Manifest: $manifestPath"
    if ($KeepMounted) { Write-Host "Mounted at: $driveRoot" }
}
finally {
    # A diskpart failure can occur after attach but before the script returns.
    # On failures, always make a best-effort detach even when KeepMounted was requested.
    if ((Test-Path -LiteralPath $VhdxPath) -and (-not $KeepMounted -or -not $completed)) {
        try {
            Invoke-DiskPartScript @(
                "select vdisk file=`"$VhdxPath`""
                'detach vdisk'
            ) | Out-Null
        }
        catch {
            if ($attached -or -not $completed) {
                Write-Warning "Could not confirm VHDX detachment: $($_.Exception.Message)"
            }
        }
    }
}
