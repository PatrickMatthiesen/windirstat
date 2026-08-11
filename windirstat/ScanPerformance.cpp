// WinDirStat - Directory Statistics
// Copyright © WinDirStat Team
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 2 of the License, or
// any later version.

#include "pch.h"
#include "ScanPerformance.h"
#include "Version.h"

#include <iomanip>

namespace
{
    ULONGLONG FileTimeValue(const FILETIME& value) noexcept
    {
        return std::bit_cast<ULONGLONG>(value);
    }

    std::string JsonQuote(const std::string_view value)
    {
        std::string result;
        result.reserve(value.size() + 2);
        result.push_back('"');
        constexpr char hex[] = "0123456789abcdef";
        for (const unsigned char c : value)
        {
            switch (c)
            {
            case '"': result.append("\\\""); break;
            case '\\': result.append("\\\\"); break;
            case '\b': result.append("\\b"); break;
            case '\f': result.append("\\f"); break;
            case '\n': result.append("\\n"); break;
            case '\r': result.append("\\r"); break;
            case '\t': result.append("\\t"); break;
            default:
                if (c < 0x20)
                {
                    result.append("\\u00");
                    result.push_back(hex[c >> 4]);
                    result.push_back(hex[c & 0x0f]);
                }
                else result.push_back(static_cast<char>(c));
                break;
            }
        }
        result.push_back('"');
        return result;
    }

    double NanosecondsToMilliseconds(const ULONGLONG value) noexcept
    {
        return static_cast<double>(value) / 1'000'000.0;
    }

    double FileTimeToMilliseconds(const ULONGLONG value) noexcept
    {
        return static_cast<double>(value) / 10'000.0;
    }

    ULONGLONG Delta(const ULONGLONG end, const ULONGLONG start) noexcept
    {
        return end >= start ? end - start : 0;
    }
}

ScanPerformance::Scope::Scope(ScanPerformance* owner, const Phase phase) noexcept :
    m_owner(owner != nullptr && owner->IsEnabled() ? owner : nullptr), m_phase(phase)
{
    if (m_owner != nullptr) m_started = Clock::now();
}

ScanPerformance::Scope::Scope(Scope&& other) noexcept :
    m_owner(std::exchange(other.m_owner, nullptr)), m_phase(other.m_phase), m_started(other.m_started)
{
}

ScanPerformance::Scope::~Scope()
{
    Stop();
}

void ScanPerformance::Scope::Stop() noexcept
{
    if (const auto owner = std::exchange(m_owner, nullptr); owner != nullptr)
    {
        owner->AddDuration(m_phase, Clock::now() - m_started);
    }
}

void ScanPerformance::Reset(const bool enabled, const bool fastScanRequested, const unsigned int scanningThreads,
    const bool hardlinksEnabled, const bool duplicatesEnabled, const bool filteringActive,
    const unsigned int targetCount)
{
    m_enabled = enabled;
    if (!m_enabled) return;

    m_fastScanRequested = fastScanRequested;
    m_hardlinksEnabled = hardlinksEnabled;
    m_duplicatesEnabled = duplicatesEnabled;
    m_filteringActive = filteringActive;
    m_scanningThreads = scanningThreads;
    m_targetCount = targetCount;
    m_scanStarted = Clock::now();
    GetSystemTime(&m_startedUtc);

    for (auto& phase : m_phaseNanoseconds) phase.store(0, std::memory_order_relaxed);
    m_mftVolumesLoaded.store(0, std::memory_order_relaxed);
    m_mftExtents.store(0, std::memory_order_relaxed);
    m_mftBytesRead.store(0, std::memory_order_relaxed);
    m_mftRecordSlots.store(0, std::memory_order_relaxed);
    m_mftValidRecords.store(0, std::memory_order_relaxed);
    m_mftBaseRecords.store(0, std::memory_order_relaxed);
    m_mftNames.store(0, std::memory_order_relaxed);
    m_files = 0;
    m_folders = 0;
    m_logicalBytes = 0;
    m_physicalBytes = 0;
    m_startKernelTime = 0;
    m_startUserTime = 0;
    m_startIo = {};
    m_startWorkingSet = 0;
    m_startPrivateBytes = 0;
    m_kernelTime = 0;
    m_userTime = 0;
    m_io = {};
    m_peakWorkingSet = 0;
    m_endWorkingSet = 0;
    m_endPrivateBytes = 0;

    FILETIME created{}, exited{}, kernel{}, user{};
    if (GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user))
    {
        m_startKernelTime = FileTimeValue(kernel);
        m_startUserTime = FileTimeValue(user);
    }
    GetProcessIoCounters(GetCurrentProcess(), &m_startIo);

    PROCESS_MEMORY_COUNTERS_EX memory{};
    memory.cb = sizeof(memory);
    if (GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&memory), sizeof(memory)))
    {
        m_startWorkingSet = memory.WorkingSetSize;
        m_startPrivateBytes = memory.PrivateUsage;
    }
}

ScanPerformance::Scope ScanPerformance::Measure(const Phase phase) noexcept
{
    return Scope(this, phase);
}

void ScanPerformance::AddDuration(const Phase phase, const Clock::duration duration) noexcept
{
    if (!m_enabled || phase == Phase::Count) return;
    const auto nanoseconds = std::chrono::duration_cast<std::chrono::nanoseconds>(duration).count();
    if (nanoseconds <= 0) return;
    m_phaseNanoseconds[static_cast<size_t>(phase)].fetch_add(static_cast<ULONGLONG>(nanoseconds),
        std::memory_order_relaxed);
}

void ScanPerformance::AddMftExtents(const ULONGLONG count) noexcept
{
    if (m_enabled) m_mftExtents.fetch_add(count, std::memory_order_relaxed);
}

void ScanPerformance::AddMftChunk(const ULONGLONG bytesRead, const ULONGLONG recordSlots,
    const ULONGLONG validRecords) noexcept
{
    if (!m_enabled) return;
    m_mftBytesRead.fetch_add(bytesRead, std::memory_order_relaxed);
    m_mftRecordSlots.fetch_add(recordSlots, std::memory_order_relaxed);
    m_mftValidRecords.fetch_add(validRecords, std::memory_order_relaxed);
}

void ScanPerformance::AddMftBaseRecords(const ULONGLONG count) noexcept
{
    if (m_enabled) m_mftBaseRecords.fetch_add(count, std::memory_order_relaxed);
}

void ScanPerformance::AddMftNames(const ULONGLONG count) noexcept
{
    if (m_enabled) m_mftNames.fetch_add(count, std::memory_order_relaxed);
}

void ScanPerformance::MarkMftVolumeLoaded() noexcept
{
    if (m_enabled) m_mftVolumesLoaded.fetch_add(1, std::memory_order_relaxed);
}

void ScanPerformance::Finish(const ULONGLONG files, const ULONGLONG folders, const ULONGLONG logicalBytes,
    const ULONGLONG physicalBytes) noexcept
{
    if (!m_enabled) return;

    m_files = files;
    m_folders = folders;
    m_logicalBytes = logicalBytes;
    m_physicalBytes = physicalBytes;
    const auto total = Clock::now() - m_scanStarted;
    m_phaseNanoseconds[static_cast<size_t>(Phase::TotalWall)].store(
        static_cast<ULONGLONG>(std::chrono::duration_cast<std::chrono::nanoseconds>(total).count()),
        std::memory_order_relaxed);

    FILETIME created{}, exited{}, kernel{}, user{};
    if (GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user))
    {
        m_kernelTime = Delta(FileTimeValue(kernel), m_startKernelTime);
        m_userTime = Delta(FileTimeValue(user), m_startUserTime);
    }

    IO_COUNTERS currentIo{};
    if (GetProcessIoCounters(GetCurrentProcess(), &currentIo))
    {
        m_io.ReadOperationCount = Delta(currentIo.ReadOperationCount, m_startIo.ReadOperationCount);
        m_io.WriteOperationCount = Delta(currentIo.WriteOperationCount, m_startIo.WriteOperationCount);
        m_io.OtherOperationCount = Delta(currentIo.OtherOperationCount, m_startIo.OtherOperationCount);
        m_io.ReadTransferCount = Delta(currentIo.ReadTransferCount, m_startIo.ReadTransferCount);
        m_io.WriteTransferCount = Delta(currentIo.WriteTransferCount, m_startIo.WriteTransferCount);
        m_io.OtherTransferCount = Delta(currentIo.OtherTransferCount, m_startIo.OtherTransferCount);
    }

    PROCESS_MEMORY_COUNTERS_EX memory{};
    memory.cb = sizeof(memory);
    if (GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&memory), sizeof(memory)))
    {
        m_peakWorkingSet = memory.PeakWorkingSetSize;
        m_endWorkingSet = memory.WorkingSetSize;
        m_endPrivateBytes = memory.PrivateUsage;
    }
}

bool ScanPerformance::WriteJson(const std::wstring& path) const
{
    if (!m_enabled || path.empty()) return false;

    const std::filesystem::path target(path);
    std::filesystem::path temporary(path);
    temporary += L".tmp";
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    if (!output) return false;

    const auto phase = [&](const Phase value)
    {
        return NanosecondsToMilliseconds(m_phaseNanoseconds[static_cast<size_t>(value)].load(std::memory_order_relaxed));
    };
    const auto utc = std::format("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        m_startedUtc.wYear, m_startedUtc.wMonth, m_startedUtc.wDay,
        m_startedUtc.wHour, m_startedUtc.wMinute, m_startedUtc.wSecond, m_startedUtc.wMilliseconds);
#ifdef NDEBUG
    constexpr std::string_view configuration = "Release";
#else
    constexpr std::string_view configuration = "Debug";
#endif

    output << std::fixed << std::setprecision(3)
        << "{\n"
        << "  \"schema_version\": 1,\n"
        << "  \"timestamp_utc\": " << JsonQuote(utc) << ",\n"
        << "  \"build\": {\n"
        << "    \"commit\": " << JsonQuote(GIT_COMMIT) << ",\n"
        << "    \"configuration\": " << JsonQuote(configuration) << "\n"
        << "  },\n"
        << "  \"settings\": {\n"
        << "    \"fast_scan_requested\": " << (m_fastScanRequested ? "true" : "false") << ",\n"
        << "    \"scanning_threads\": " << m_scanningThreads << ",\n"
        << "    \"hardlinks_enabled\": " << (m_hardlinksEnabled ? "true" : "false") << ",\n"
        << "    \"duplicates_enabled\": " << (m_duplicatesEnabled ? "true" : "false") << ",\n"
        << "    \"filtering_active\": " << (m_filteringActive ? "true" : "false") << ",\n"
        << "    \"target_count\": " << m_targetCount << "\n"
        << "  },\n"
        << "  \"engine\": {\n"
        << "    \"fast_scan_used\": " << (m_mftVolumesLoaded.load(std::memory_order_relaxed) > 0 ? "true" : "false") << ",\n"
        << "    \"mft_volumes_loaded\": " << m_mftVolumesLoaded.load(std::memory_order_relaxed) << "\n"
        << "  },\n"
        << "  \"wall_ms\": {\n"
        << "    \"setup\": " << phase(Phase::SetupWall) << ",\n"
        << "    \"enumeration_and_materialization\": " << phase(Phase::EnumerationWall) << ",\n"
        << "    \"hardlink_adjustment\": " << phase(Phase::HardlinkWall) << ",\n"
        << "    \"finalization\": " << phase(Phase::FinalizationWall) << ",\n"
        << "    \"extension_finalization\": " << phase(Phase::ExtensionFinalizeWall) << ",\n"
        << "    \"ui_publication\": " << phase(Phase::UiPublicationWall) << ",\n"
        << "    \"heap_minimization\": " << phase(Phase::HeapMinWall) << ",\n"
        << "    \"total_settled\": " << phase(Phase::TotalWall) << "\n"
        << "  },\n"
        << "  \"parallel_work_ms\": {\n"
        << "    \"mft_load\": " << phase(Phase::MftLoadWork) << ",\n"
        << "    \"mft_discovery\": " << phase(Phase::MftDiscoveryWork) << ",\n"
        << "    \"mft_read_wait\": " << phase(Phase::MftReadWork) << ",\n"
        << "    \"mft_parse_and_index\": " << phase(Phase::MftParseWork) << ",\n"
        << "    \"item_processing\": " << phase(Phase::ItemProcessingWork) << "\n"
        << "  },\n"
        << "  \"mft\": {\n"
        << "    \"extents\": " << m_mftExtents.load(std::memory_order_relaxed) << ",\n"
        << "    \"bytes_read\": " << m_mftBytesRead.load(std::memory_order_relaxed) << ",\n"
        << "    \"record_slots\": " << m_mftRecordSlots.load(std::memory_order_relaxed) << ",\n"
        << "    \"valid_records\": " << m_mftValidRecords.load(std::memory_order_relaxed) << ",\n"
        << "    \"base_records\": " << m_mftBaseRecords.load(std::memory_order_relaxed) << ",\n"
        << "    \"names\": " << m_mftNames.load(std::memory_order_relaxed) << "\n"
        << "  },\n"
        << "  \"result\": {\n"
        << "    \"files\": " << m_files << ",\n"
        << "    \"folders\": " << m_folders << ",\n"
        << "    \"logical_bytes\": " << m_logicalBytes << ",\n"
        << "    \"physical_bytes\": " << m_physicalBytes << "\n"
        << "  },\n"
        << "  \"process\": {\n"
        << "    \"kernel_cpu_ms\": " << FileTimeToMilliseconds(m_kernelTime) << ",\n"
        << "    \"user_cpu_ms\": " << FileTimeToMilliseconds(m_userTime) << ",\n"
        << "    \"read_operations\": " << m_io.ReadOperationCount << ",\n"
        << "    \"write_operations\": " << m_io.WriteOperationCount << ",\n"
        << "    \"read_transfer_bytes\": " << m_io.ReadTransferCount << ",\n"
        << "    \"write_transfer_bytes\": " << m_io.WriteTransferCount << ",\n"
        << "    \"working_set_start_bytes\": " << m_startWorkingSet << ",\n"
        << "    \"working_set_end_bytes\": " << m_endWorkingSet << ",\n"
        << "    \"process_peak_working_set_bytes\": " << m_peakWorkingSet << ",\n"
        << "    \"private_bytes_start\": " << m_startPrivateBytes << ",\n"
        << "    \"private_bytes_end\": " << m_endPrivateBytes << "\n"
        << "  }\n"
        << "}\n";

    output.flush();
    const bool writeSucceeded = output.good();
    output.close();
    if (!writeSucceeded)
    {
        DeleteFileW(temporary.c_str());
        return false;
    }
    if (!MoveFileExW(temporary.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
    {
        DeleteFileW(temporary.c_str());
        return false;
    }
    return true;
}
