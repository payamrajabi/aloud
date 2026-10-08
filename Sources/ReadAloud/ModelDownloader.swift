import AppKit
import CryptoKit
import Foundation

/// Asks before downloading a model that was removed in Settings (or never finished downloading).
enum DownloadPrompt {
    static func confirm(model: String, size: String, feature: String) -> Bool {
        if DebugScript.isActive { return true }
        NSApp.activate(ignoringOtherApps: true)
        return alert(model: model, size: size, feature: feature).runModal() == .alertFirstButtonReturn
    }

    static func alert(model: String, size: String, feature: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Download \(model)?"
        alert.informativeText = "\(feature) needs a one-time download of about \(size). After that it runs entirely on your Mac, even offline."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Not Now")
        return alert
    }
}

/// Where downloaded models live: ~/Library/Application Support/ReadAloud/models.
enum ModelStore {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["READALOUD_MODELS_DIR"] {  // for testing fresh installs
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ReadAloud/models")
    }

    /// Removes what interrupted downloads left behind: the hidden .download-, .unpack- and
    /// .migrate- items in the models folder, which no later attempt reuses and which can
    /// hold hundreds of MB if Aloud quit, crashed or was logged out of mid-download.
    /// Skips anything a download in progress is using. Call on the main thread.
    static func removeAbandonedDownloads() {
        let fm = FileManager.default
        let dir = root
        let abandoned = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { name in
            [".download-", ".unpack-", ".migrate-"].contains { name.hasPrefix($0) } && !ModelDownloader.inUse.contains(name)
        }
        guard !abandoned.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for name in abandoned { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        }
    }
}

/// Downloads a model into Application Support, reporting progress: either a tar.bz2
/// archive (unpacked into a hidden folder first), or a list of individual files
/// (collected in a hidden folder and checked against their sizes and checksums).
/// Either way the model is moved into place only when it's complete, so a
/// half-downloaded model never looks installed.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    struct RemoteFile {
        let name: String
        let url: URL
        let size: Int64
        let sha256: String?
    }

    private var onProgress: ((Double) -> Void)?
    private var onDone: ((Error?) -> Void)?
    private var session: URLSession?
    private var destination: URL!
    // Individual files: those still to fetch, all of them (for the checksums), where they collect.
    private var queue: [RemoteFile] = []
    private var expected: [RemoteFile] = []
    private var staging: URL?
    private var bytesDone: Int64 = 0
    private var bytesTotal: Int64 = 0

    var isRunning: Bool { session != nil }

    /// Names of the hidden folders and archives that downloads in progress are working in,
    /// so ModelStore.removeAbandonedDownloads leaves them alone. Main thread only.
    fileprivate static var inUse = Set<String>()

    /// Downloads a tar.bz2 archive and unpacks it into `directory`.
    func download(_ url: URL, into directory: URL, progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        guard session == nil else { return }
        onProgress = progress
        onDone = completion
        destination = directory
        queue = []
        staging = nil
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    /// Fetches `files` one after another; when all have arrived intact they're moved
    /// into `directory` (created if needed, existing files replaced).
    func download(files: [RemoteFile], into directory: URL, progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        guard session == nil, let first = files.first else { return }
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".download-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            completion(error)
            return
        }
        onProgress = progress
        onDone = completion
        destination = directory
        queue = files
        expected = files
        self.staging = staging
        Self.inUse.insert(staging.lastPathComponent)
        bytesDone = 0
        bytesTotal = files.reduce(0) { $0 + $1.size }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        session.downloadTask(with: first.url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if staging != nil {
            guard bytesTotal > 0 else { return }
            onProgress?(min(1, Double(bytesDone + totalBytesWritten) / Double(bytesTotal)))
        } else if totalBytesExpectedToWrite > 0 {
            onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(Self.error("The download failed (HTTP \(http.statusCode))."))
            return
        }
        if let staging {
            finishedFile(at: location, staging: staging)
            return
        }
        // The temporary file disappears when this method returns, so move it first.
        let fm = FileManager.default
        let archive = destination.appendingPathComponent(".download-\(UUID().uuidString).tar.bz2")
        let staging = destination.appendingPathComponent(".unpack-\(UUID().uuidString)")
        let working = [archive.lastPathComponent, staging.lastPathComponent]
        Self.inUse.formUnion(working)
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: archive)
        } catch {
            Self.inUse.subtract(working)
            finish(error)
            return
        }
        let dest = destination!
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                let tar = Process()
                tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tar.arguments = ["-xjf", archive.path, "-C", staging.path]
                try tar.run()
                tar.waitUntilExit()
                guard tar.terminationStatus == 0 else { throw Self.error("Couldn't unpack the model.") }
                for item in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                    let target = dest.appendingPathComponent(item.lastPathComponent)
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.moveItem(at: item, to: target)
                }
            } catch { failure = error }
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: archive)
            DispatchQueue.main.async {
                Self.inUse.subtract(working)
                self.finish(failure)
            }
        }
    }

    /// One of several files arrived: keep it and start the next, or, after the last,
    /// verify them all and move them into place.
    private func finishedFile(at location: URL, staging: URL) {
        let fm = FileManager.default
        let file = queue.removeFirst()
        do {
            let target = staging.appendingPathComponent(file.name)
            try fm.moveItem(at: location, to: target)
            let size = (try fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? -1
            if file.sha256 != nil, size != file.size {
                throw Self.error("\(file.name) is the wrong size (\(size) bytes, expected \(file.size)).")
            }
        } catch {
            finish(error)
            return
        }
        bytesDone += file.size
        if let next = queue.first {
            session?.downloadTask(with: next.url).resume()
            return
        }
        let checks = expected
        let dest = destination!
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do {
                for f in checks {
                    if let sha = f.sha256, try Self.sha256(of: staging.appendingPathComponent(f.name)) != sha {
                        throw Self.error("\(f.name) didn't download correctly (checksum mismatch).")
                    }
                }
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for f in checks {
                    let target = dest.appendingPathComponent(f.name)
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.moveItem(at: staging.appendingPathComponent(f.name), to: target)
                }
            } catch { failure = error }
            DispatchQueue.main.async { self.finish(failure) }
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }

    private func finish(_ error: Error?) {
        if let staging {
            try? FileManager.default.removeItem(at: staging)
            Self.inUse.remove(staging.lastPathComponent)
        }
        staging = nil
        queue = []
        expected = []
        let done = onDone
        session?.finishTasksAndInvalidate()
        session = nil
        onDone = nil
        onProgress = nil
        done?(error)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "ReadAloud", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
