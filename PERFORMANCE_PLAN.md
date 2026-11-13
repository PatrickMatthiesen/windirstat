# WinDirStat Performance Improvement Plan

## Objective

Make whole-volume NTFS scans substantially faster and less memory-intensive without
regressing scan accuracy, non-NTFS and network enumeration, refresh behavior, or UI
responsiveness.

The primary goal is to preserve WinDirStat's current feature set while recovering
the bulk-processing advantage of the MFT. The current fast path reads the MFT in
bulk, but then replays its results through a directory-at-a-time, object-per-entry
pipeline shared with basic filesystem enumeration.

## Provisional success criteria

Phase 0 will establish reproducible baselines and may refine these targets.

- Reduce median end-to-end fast-scan time by at least 3x on the one-million-entry
  NTFS fixture.
- Reduce peak working set during the fast scan by at least 40%.
- Avoid regressions greater than 5% in basic folder, network, and non-NTFS scans.
- Preserve logical and physical sizes, timestamps, attributes, hardlink behavior,
  filters, extension totals, and serialized CSV/JSON results.
- Keep the UI responsive throughout scanning and avoid synchronous per-entry UI
  work from scan workers.

## Guardrails

- Optimize from measurements rather than elapsed-time anecdotes.
- Judge each optimization against a pinned telemetry-enabled WinDirStat baseline
  on the same fixture and host. External tools are not an optimization gate.
- Land independent changes in small, benchmarked commits.
- Keep the existing C++/Win32 application; a language rewrite is not part of this
  effort.
- Separate the scan/data model from the UI incrementally rather than rewriting the
  application in one step.
- Retain the basic enumeration path for folders, network shares, and non-NTFS
  filesystems.
- Treat duplicate hashing as a separate workload from directory-size scanning.
- Never use a developer's mutable system drive as the only performance fixture.

## Phase 0: Build a performance laboratory

### 0.1 Add phase-level instrumentation

Record high-resolution duration and resource counters for:

1. Volume discovery and MFT extent discovery.
2. Raw MFT reads.
3. MFT record parsing.
4. Parent/child index construction.
5. scan-model materialization.
6. Size, timestamp, extension, top-N, and hardlink aggregation.
7. Per-directory sorting.
8. UI publication and time to first interactive result.
9. Total time until the scan is settled.

Expose the measurements in machine-readable JSON from quiet CLI scans. Keep normal
user-facing output unchanged unless diagnostics are explicitly requested.

### 0.2 Add reproducible fixtures

Create a benchmark harness under `benchmarks/` with disposable, generated NTFS
VHDX fixtures. Include at least:

- 100,000 and 1,000,000 mixed files.
- A wide directory containing at least 100,000 children.
- A deeply nested tree.
- Many hardlinks and multiple names for the same file record.
- Sparse, compressed, resident, WOF, and reparse-point records.
- A large MFT containing a high percentage of unused records.
- A representative fixture for the basic enumeration engine.

The fixture definition and expected inventory should be source-controlled; large
generated disk images should not be committed.

### 0.3 Establish benchmark methodology

- Build x64 Release with the same compiler and linker settings used for releases.
- Run at least one warmup and five measured iterations.
- Interleave baseline and candidate runs, alternating which build runs first, to
  reduce temperature, cache, and background-load ordering bias.
- Report median, minimum, maximum, and median absolute deviation.
- Record CPU model, storage type, Windows build, Defender state, elevation state,
  working set, allocation count, CPU time, and bytes read.
- Measure warm-cache and explicitly identified cold-cache scenarios separately.
- Run thread-count variants at 1, 4, and 16 workers.
- Store results as build artifacts; start with reporting-only CI rather than flaky
  pass/fail timing gates.
- Require baseline and candidate inventories to match before reporting a speedup.
- Record both executable hashes and embedded build commits in every comparison.
- Continue running the existing correctness suite and compare exported inventories
  between the fast and basic engines.

### 0.4 Add focused microbenchmarks

Refactor pure operations behind byte-span and record-batch inputs so they can be
measured without mounting a volume:

- MFT fixup and attribute parsing.
- Record-to-node conversion.
- Parent/child edge construction.
- Bottom-up aggregation.
- Extension reduction.
- Per-directory sorting.

### Exit criteria

- A single documented command produces repeatable benchmark results.
- Phase timings explain at least 90% of end-to-end wall time.
- Fast and basic engines produce equivalent expected inventories on applicable
  fixtures.
- Baseline results for the unmodified implementation are archived.

## Phase 1: Remove avoidable work from the current pipeline

These changes should remain compatible with the current `CItem` model and be
measured independently.

### 1.1 Avoid unused path and name construction

- Check whether filtering is active before constructing full paths.
- Return `std::wstring_view` for MFT names where ownership permits it.
- Build a full path only for filters or features that require one.
- Avoid copying the same MFT filename during filtering, `CItem` construction, and
  extension extraction.

### 1.2 Batch secondary statistics

- Accumulate extension counts and byte totals per worker, then merge once.
- Maintain a bounded per-worker top-N heap and merge the heaps at completion.
- Give suspension checks an atomic fast path so an unsuspended scan does not take
  the central queue mutex for every file.
- Batch progress notifications by elapsed time or processed-record count.

### 1.3 Reduce finalization churn

- Remove per-directory `shrink_to_fit` from the hot completion path.
- Sort only when required by the active view or treemap calculation.
- Track dirty directories so later corrections do not blindly repeat completed
  work.

### Exit criteria

- Each retained optimization has a benchmark demonstrating its effect.
- Correctness tests and fast/basic inventory comparisons pass.
- No new long-lived compatibility abstraction is introduced solely for these
  quick wins.

## Phase 2: Replace the MFT ingestion bottleneck

### 2.1 Partition by record ranges, not MFT extents

The current parser parallelizes over physical MFT data runs. A contiguous MFT can
therefore collapse parsing to one work item.

- Read sequential MFT chunks into aligned buffers.
- Divide parsing into fixed record ranges independent of physical fragmentation.
- Preserve record numbers and deterministic ordering in the merged output.
- Use thread-local parsed-record and parent-edge batches.

### 2.2 Pipeline I/O and parsing

- Keep at least two aligned buffers in flight.
- Read buffer N+1 while workers parse buffer N.
- Bound the number of outstanding reads to avoid harming HDD performance.
- Select queue depth based on measured storage behavior rather than CPU count.
- Preserve cancellation and error reporting at chunk boundaries.

### 2.3 Eliminate per-record global map locks

- Pre-size record-indexed storage from the MFT record count.
- Store base-record metadata in a dense or segmented array keyed by record number.
- Store parent-child relationships as flat edge batches.
- Merge thread-local batches after parsing instead of inserting every record into
  shared `unordered_map` instances.
- Resolve extension-record and multi-name cases explicitly during the merge.

### 2.4 Evaluate unused-record skipping

Measure `$MFT::$Bitmap` as an optional optimization for unusually large, sparse
MFTs. Retain it only when benchmarks show a meaningful win after accounting for
the extra I/O and complexity.

### Exit criteria

- Parsing uses multiple cores even when the MFT has one physical extent.
- Raw I/O overlaps record parsing on storage where that improves results.
- There is no global lock acquisition per valid MFT record or filename.
- Parser tests cover corrupt bounds, extension records, multiple names, and all
  currently supported data/reparse forms.

## Phase 3: Introduce a compact scan snapshot

### 3.1 Define scanner-owned data structures

Introduce stable `NodeId` values and a compact arena containing fields such as:

```text
NodeId, parent NodeId, name slice, logical size, physical size,
last-write time, attributes, reparse tag, and file-record identity
```

- Store names in a pooled UTF-16 buffer.
- Store child edges contiguously where practical.
- Avoid a virtual UI base class and individual heap allocation per filesystem node.
- Make the completed snapshot immutable except through explicit refresh operations.

### 3.2 Aggregate once, bottom-up

- Build parent/child relationships before computing subtree statistics.
- Compute size, count, and last-write aggregates in one bottom-up pass.
- Merge extension and top-N worker reductions during this pass.
- Account for hardlinks before publishing final subtree sizes.
- Use parallelism across independent subtrees where benchmarks justify it.

### 3.3 Preserve the current application incrementally

Use a transitional adapter:

1. Build the compact snapshot.
2. Materialize the existing `CItem` tree from the already aggregated snapshot.
3. Validate behavior and measure the remaining materialization cost.
4. Migrate views and commands from raw `CItem*` identity to stable `NodeId` queries.
5. Remove the duplicate legacy tree after all consumers use the snapshot.

### Exit criteria

- The MFT maps and the full `CItem` tree are not simultaneously retained as two
  complete representations.
- Aggregation is linear in node and edge count rather than node count multiplied by
  directory depth.
- Refresh, selection, search, cleanup, serialization, and file watching have
  documented `NodeId` behavior.

## Phase 4: Decouple scan publication from the UI

### 4.1 Introduce a query-oriented UI boundary

- Keep scan workers free of HWNDs and synchronous UI callbacks.
- Publish immutable snapshots or bounded progress batches.
- Materialize presentation objects only for visible rows and active graph regions.
- Resolve paths on demand from parent/name data, with bounded caching.

### 4.2 Coalesce expensive view work

- Throttle progress and row updates to a human-visible cadence.
- Sort only dirty visible sibling ranges while scanning.
- Perform the definitive treemap order once the relevant subtree is stable.
- Avoid rebuilding visible-row lookup maps every 25 ms when nothing relevant
  changed.

### Exit criteria

- No per-file scan operation synchronously blocks on the UI thread.
- Expanding or interacting with the tree remains responsive during a scan.
- UI update CPU usage is reported independently from scanner CPU usage.

## Phase 5: Tune, validate, and establish regression policy

- Profile the new pipeline with ETW/WPA, Visual Studio Profiler, or VTune.
- Tune buffers, batch sizes, arena growth, and worker counts from evidence.
- Compare PGO with and without the representative benchmark scenarios.
- Run the complete correctness suite on x64, x86, and ARM64 release builds.
- Validate SSD, HDD, network, ReFS/FAT/basic-enumeration, compressed, sparse,
  cloud-placeholder, inaccessible, and reparse-point scenarios.
- Add a conservative performance gate only after variance is understood—for
  example, fail on a statistically significant regression above 10% across several
  runs rather than on one elapsed-time result.

## Delivery sequence

Keep changes reviewable and bisectable in this order:

1. Benchmark harness and phase telemetry.
2. Filter/path allocation removal.
3. Batched extension and top-N accounting.
4. Suspension/progress fast paths and finalization cleanup.
5. Record-range MFT parser with thread-local batches.
6. Pipelined MFT I/O.
7. Compact scan snapshot and bottom-up aggregation.
8. Transitional `CItem` adapter.
9. Lazy UI facade and removal of the duplicate legacy model.
10. Final tuning and performance regression policy.

Every delivery should include its benchmark delta, peak-memory delta, correctness
results, and any scenario where it regresses performance.

## Expected outcome

The early phases should provide modest wins and, more importantly, reliable
measurement. The large improvement should come from phases 2 through 4: parsing
independent of MFT fragmentation, eliminating per-record synchronization, replacing
millions of small allocations with compact storage, aggregating once bottom-up, and
keeping UI work out of the scan pipeline.
