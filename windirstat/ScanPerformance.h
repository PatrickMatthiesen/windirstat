// WinDirStat - Directory Statistics
// Copyright © WinDirStat Team
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 2 of the License, or
// any later version.

#pragma once

#include "pch.h"

class ScanPerformance final
{
public:
    using Clock = std::chrono::steady_clock;

    enum class Phase : size_t
    {
        SetupWall,
        EnumerationWall,
        MftLoadWork,
        MftDiscoveryWork,
        MftReadWork,
        MftParseWork,
        ItemProcessingWork,
        HardlinkWall,
        FinalizationWall,
        ExtensionFinalizeWall,
        UiPublicationWall,
        HeapMinWall,
        TotalWall,
        Count
    };

    class Scope final
    {
    public:
        Scope() = default;
        Scope(ScanPerformance* owner, Phase phase) noexcept;
        Scope(const Scope&) = delete;
        Scope& operator=(const Scope&) = delete;
        Scope(Scope&& other) noexcept;
        Scope& operator=(Scope&&) = delete;
        ~Scope();

        void Stop() noexcept;

    private:
        ScanPerformance* m_owner = nullptr;
        Phase m_phase = Phase::Count;
        Clock::time_point m_started{};
    };

    void Reset(bool enabled, bool fastScanRequested, unsigned int scanningThreads,
        bool hardlinksEnabled, bool duplicatesEnabled, bool filteringActive,
        unsigned int targetCount);
    bool IsEnabled() const noexcept { return m_enabled; }
    void SetFilteringActive(bool active) noexcept { m_filteringActive = active; }
    Scope Measure(Phase phase) noexcept;
    void AddDuration(Phase phase, Clock::duration duration) noexcept;

    void AddMftExtents(ULONGLONG count) noexcept;
    void AddMftChunk(ULONGLONG bytesRead, ULONGLONG recordSlots, ULONGLONG validRecords) noexcept;
    void AddMftBaseRecords(ULONGLONG count) noexcept;
    void AddMftNames(ULONGLONG count) noexcept;
    void MarkMftVolumeLoaded() noexcept;

    void Finish(ULONGLONG files, ULONGLONG folders, ULONGLONG logicalBytes,
        ULONGLONG physicalBytes) noexcept;
    bool WriteJson(const std::wstring& path) const;

private:
    static constexpr size_t PhaseCount = static_cast<size_t>(Phase::Count);

    bool m_enabled = false;
    bool m_fastScanRequested = false;
    bool m_hardlinksEnabled = false;
    bool m_duplicatesEnabled = false;
    bool m_filteringActive = false;
    unsigned int m_scanningThreads = 0;
    unsigned int m_targetCount = 0;
    Clock::time_point m_scanStarted{};
    SYSTEMTIME m_startedUtc{};

    std::array<std::atomic<ULONGLONG>, PhaseCount> m_phaseNanoseconds{};
    std::atomic<ULONGLONG> m_mftVolumesLoaded = 0;
    std::atomic<ULONGLONG> m_mftExtents = 0;
    std::atomic<ULONGLONG> m_mftBytesRead = 0;
    std::atomic<ULONGLONG> m_mftRecordSlots = 0;
    std::atomic<ULONGLONG> m_mftValidRecords = 0;
    std::atomic<ULONGLONG> m_mftBaseRecords = 0;
    std::atomic<ULONGLONG> m_mftNames = 0;

    ULONGLONG m_files = 0;
    ULONGLONG m_folders = 0;
    ULONGLONG m_logicalBytes = 0;
    ULONGLONG m_physicalBytes = 0;

    ULONGLONG m_startKernelTime = 0;
    ULONGLONG m_startUserTime = 0;
    IO_COUNTERS m_startIo{};
    SIZE_T m_startWorkingSet = 0;
    SIZE_T m_startPrivateBytes = 0;

    ULONGLONG m_kernelTime = 0;
    ULONGLONG m_userTime = 0;
    IO_COUNTERS m_io{};
    SIZE_T m_peakWorkingSet = 0;
    SIZE_T m_endWorkingSet = 0;
    SIZE_T m_endPrivateBytes = 0;
};
