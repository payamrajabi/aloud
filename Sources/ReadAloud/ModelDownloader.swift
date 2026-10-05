import Foundation

/// Downloads and unpacks a model archive into Application Support, reporting progress.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    private var onProgress: ((Double) -> Void)?
    private var onDone: ((Error?) -> Void)?
    private var session: URLSession?
    private var destination: URL!

    var isRunning: Bool { session != nil }

    func download(_ url: URL, into directory: URL, progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        guard session == nil else { return }
        onProgress = progress
        onDone = completion
        destination = directory
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
        // The temporary file disappears when this method returns, so move it first.
        let fm = FileManager.default
        let archive = destination.appendingPathComponent("download-\(UUID().uuidString).tar.bz2")
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: archive)
        } catch {
            finish(error)
            return
        }
        let dest = destination!
        DispatchQueue.global(qos: .userInitiated).async {
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xjf", archive.path, "-C", dest.path]
            var failure: Error?
            do {
                try tar.run()
                tar.waitUntilExit()
                if tar.terminationStatus != 0 {
                    failure = NSError(domain: "ReadAloud", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't unpack the model."])
                }
            } catch { failure = error }
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
}
