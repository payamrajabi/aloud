import AppKit
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
}

/// Downloads and unpacks a model archive into Application Support, reporting progress.
/// The archive is unpacked into a hidden folder first and moved into place only when
/// it's complete, so a half-unpacked model never looks installed. A single-file model
/// (`saveAs`) is moved into place as is.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    private var onProgress: ((Double) -> Void)?
    private var onDone: ((Error?) -> Void)?
    private var session: URLSession?
    private var destination: URL!
    private var saveAs: String?

    var isRunning: Bool { session != nil }

    func download(_ url: URL, into directory: URL, saveAs fileName: String? = nil,
                  progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        guard session == nil else { return }
        onProgress = progress
        onDone = completion
        destination = directory
        saveAs = fileName
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(Self.error("The download failed (HTTP \(http.statusCode))."))
            return
        }
        // The temporary file disappears when this method returns, so move it first.
        let fm = FileManager.default
        let archive = destination.appendingPathComponent(".download-\(UUID().uuidString).tar.bz2")
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: archive)
        } catch {
            finish(error)
            return
        }
        if let saveAs {
            do {
                let target = destination.appendingPathComponent(saveAs)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: archive, to: target)
                finish(nil)
            } catch {
                try? fm.removeItem(at: archive)
                finish(error)
            }
            return
        }
        let dest = destination!
        DispatchQueue.global(qos: .userInitiated).async {
            let staging = dest.appendingPathComponent(".unpack-\(UUID().uuidString)")
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
            DispatchQueue.main.async { self.finish(failure) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }

    private func finish(_ error: Error?) {
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
