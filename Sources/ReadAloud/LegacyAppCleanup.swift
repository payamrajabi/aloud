import AppKit

/// Aloud was called Read Aloud before 1.2 and kept the same bundle ID, so people who
/// had Read Aloud and then installed Aloud ended up with both. On launch, the installed
/// copy quits and trashes older copies in the Applications folders. If an old copy
/// carries the voice model and we don't have one yet, the model moves over first,
/// which saves a 330 MB download.
enum LegacyAppCleanup {
    struct Outcome {
        var trashed: [URL] = []
        var failed: [URL] = []
        var terminatedOthers = false
        var migratedVoice = false
    }

    static let legacyName = "Read Aloud.app"

    private static var me: URL { Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL }

    private static var applicationFolders: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    private static func isInApplications(_ url: URL) -> Bool {
        applicationFolders.contains(url.deletingLastPathComponent())
    }

    /// Calls `completion` on the main queue once everything is done (immediately if there's nothing to do).
    static func run(completion: @escaping (Outcome) -> Void) {
        // Only the installed copy tidies up, so a build run from elsewhere never touches /Applications.
        guard let id = Bundle.main.bundleIdentifier, isInApplications(me) else {
            completion(Outcome())
            return
        }
        let old = oldCopies(bundleID: id)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL != me
        }
        guard !old.isEmpty || !others.isEmpty else {
            completion(Outcome())
            return
        }
        var outcome = Outcome()
        outcome.terminatedOthers = !others.isEmpty
        others.forEach { $0.terminate() }
        let wait: Double = others.isEmpty ? 0 : 2
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
            DispatchQueue.global(qos: .utility).async {
                if !others.isEmpty { usleep(300_000) }  // let a force-quit release its files
                outcome.migratedVoice = old.contains { migrateVoice(from: $0) }
                DispatchQueue.main.async {
                    trash(old, outcome: outcome, completion: completion)
                }
            }
        }
    }

    /// Other copies with our bundle ID, directly inside /Applications or ~/Applications,
    /// that are either the old "Read Aloud.app" or an older version than this one.
    private static func oldCopies(bundleID id: String) -> [URL] {
        let fm = FileManager.default
        let candidates = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
            + applicationFolders.map { $0.appendingPathComponent(legacyName) }
        let myVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var seen = Set<String>()
        return candidates
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { url in
                guard seen.insert(url.path).inserted, url != me, isInApplications(url),
                      fm.fileExists(atPath: url.path),
                      let bundle = Bundle(url: url), bundle.bundleIdentifier == id else { return false }
                if url.lastPathComponent == legacyName { return true }
                let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                return version.compare(myVersion, options: .numeric) == .orderedAscending
            }
    }

    /// Moves (or copies) a bundled voice model into Application Support when we don't have one.
    private static func migrateVoice(from app: URL) -> Bool {
        let fm = FileManager.default
        let source = app.appendingPathComponent("Contents/Resources/\(KokoroEngine.modelName)")
        guard fm.fileExists(atPath: source.appendingPathComponent("model.onnx").path),
              !KokoroEngine.isModelInstalled else { return false }
        let root = ModelStore.root
        let target = KokoroEngine.downloadedModelDirectory
        let staging = root.appendingPathComponent(".migrate-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: source, to: staging)
            } catch {
                try fm.copyItem(at: source, to: staging)
            }
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }  // a partial earlier attempt
            try fm.moveItem(at: staging, to: target)
            return true
        } catch {
            try? fm.removeItem(at: staging)
            return false
        }
    }

    private static func trash(_ apps: [URL], outcome: Outcome, completion: @escaping (Outcome) -> Void) {
        guard !apps.isEmpty else {
            completion(outcome)
            return
        }
        NSWorkspace.shared.recycle(apps) { trashed, _ in
            DispatchQueue.main.async {
                var outcome = outcome
                outcome.trashed = Array(trashed.keys)
                outcome.failed = apps.filter { trashed[$0] == nil }
                completion(outcome)
            }
        }
    }
}
