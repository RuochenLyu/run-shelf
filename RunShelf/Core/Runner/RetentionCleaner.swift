import Foundation

enum RetentionCleaner {
    static func clean(taskDirectoryURL: URL, policy: RetentionPolicy, preserving runIdToPreserve: String? = nil) {
        let fileManager = FileManager.default
        let runsURL = taskDirectoryURL.appendingPathComponent("runs", isDirectory: true)
        guard let runDirectories = try? fileManager.contentsOfDirectory(
            at: runsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let records: [(url: URL, record: RunRecord)] = runDirectories.compactMap { runDirectory in
            guard (try? runDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let metaURL = runDirectory.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL), let record = try? decoder.decode(RunRecord.self, from: data) else {
                return nil
            }
            return (runDirectory, record)
        }
        .sorted { $0.record.startedAt > $1.record.startedAt }

        let maxRuns = max(policy.maxRuns, 1)
        let cutoff = Calendar.current.date(byAdding: .day, value: -max(policy.days, 1), to: Date()) ?? .distantPast

        for (index, item) in records.enumerated() {
            guard item.record.runId != runIdToPreserve else { continue }
            let exceedsCount = index >= maxRuns
            let exceedsAge = item.record.startedAt < cutoff
            if exceedsCount || exceedsAge {
                try? fileManager.removeItem(at: item.url)
            }
        }
    }
}
