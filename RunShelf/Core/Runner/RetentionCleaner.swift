import Foundation

enum RetentionCleaner {
    static func clean(
        taskDirectoryURL: URL,
        policy: RetentionPolicy,
        preserving runIdToPreserve: String? = nil,
        now: Date = Date(),
        orphanGracePeriod: TimeInterval = 5 * 60,
        diagnosticLogger: (String) -> Void = { NSLog("%@", $0) }
    ) {
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
        var preservedRunIDs = activeClaimRunIDs(taskDirectoryURL: taskDirectoryURL, decoder: decoder, fileManager: fileManager)
        if let runIdToPreserve {
            preservedRunIDs.insert(runIdToPreserve)
        }

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
        let cutoff = Calendar.current.date(byAdding: .day, value: -max(policy.days, 1), to: now) ?? .distantPast

        for (index, item) in records.enumerated() {
            guard !preservedRunIDs.contains(item.record.runId) else { continue }
            let exceedsCount = index >= maxRuns
            let exceedsAge = item.record.startedAt < cutoff
            if exceedsCount || exceedsAge {
                try? fileManager.removeItem(at: item.url)
            }
        }

        let validRunDirectories = Set(records.map { $0.url.standardizedFileURL })
        for runDirectory in runDirectories where !validRunDirectories.contains(runDirectory.standardizedFileURL) {
            let runID = runDirectory.lastPathComponent
            guard !preservedRunIDs.contains(runID) else { continue }
            let metaURL = runDirectory.appendingPathComponent("meta.json")
            if fileManager.fileExists(atPath: metaURL.path) {
                diagnosticLogger("保留无法解码的运行记录：\(metaURL.path)")
                continue
            }
            guard let values = try? runDirectory.resourceValues(forKeys: [
                .isDirectoryKey,
                .contentModificationDateKey
            ]), values.isDirectory == true, let modifiedAt = values.contentModificationDate else {
                continue
            }
            guard now.timeIntervalSince(modifiedAt) > max(orphanGracePeriod, 0) else { continue }
            try? fileManager.removeItem(at: runDirectory)
        }
    }

    private static func activeClaimRunIDs(
        taskDirectoryURL: URL,
        decoder: JSONDecoder,
        fileManager: FileManager
    ) -> Set<String> {
        let rootURL = taskDirectoryURL.appendingPathComponent(".run-claim", isDirectory: true)
        var claimURLs = [rootURL.appendingPathComponent("claim.json")]
        let childDirectories = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        claimURLs.append(contentsOf: childDirectories.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return url.appendingPathComponent("claim.json")
        })

        return Set(claimURLs.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let claim = try? decoder.decode(TaskRunClaim.self, from: data)
            else {
                return nil
            }
            return claim.runId
        })
    }
}
