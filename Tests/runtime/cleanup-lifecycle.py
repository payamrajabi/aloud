#!/usr/bin/env python3
"""Real cleanup queues with a blocked engine stub; no model, audio or downloads.

Compiles the actual TranscriptCleaner source into a temporary helper and checks
normal completion, cancellation during inference, and resetting a recording.
"""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STUB = r'''
enum DebugScript { static let args: [String] = [] }
enum ModelStore { static let root = URL(fileURLWithPath: CommandLine.arguments[1]) }
final class LlamaEngine {
    struct LoadError: Error {}
    static let entered = DispatchSemaphore(value: 0)
    static let release = DispatchSemaphore(value: 0)
    let rememberedBytes = 0
    init(path: String) throws {}
    func remember(prefix: String) -> Bool { true }
    func forget(prefix: String) {}
    func complete(prompt: String, maxTokens: Int, stop: ((String) -> Bool)? = nil) -> String? {
        Self.entered.signal()
        precondition(Self.release.wait(timeout: .now() + 5) == .success)
        return "Hello world today"
    }
}
try FileManager.default.createDirectory(at: TranscriptCleaner.modelDirectory, withIntermediateDirectories: true)
try Data().write(to: TranscriptCleaner.modelPath)
let cleaner = TranscriptCleaner()
precondition(cleaner.reset())
cleaner.waitUntilIdle()
cleaner.add("Hello world today")
precondition(LlamaEngine.entered.wait(timeout: .now() + 2) == .success)
cleaner.willFinish()
var completions = [String?]()
cleaner.finish { completions.append($0) }
let scenario = CommandLine.arguments[2]
if scenario == "cancel" { cleaner.cancel() }
if scenario == "reset" { precondition(cleaner.reset()) }
LlamaEngine.release.signal()
cleaner.waitUntilIdle()
if scenario == "cancel-before-callback" { cleaner.cancel() }
let deadline = Date().addingTimeInterval(0.3)
while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
if scenario == "normal" {
    precondition(completions.count == 1 && completions[0] == "Hello world today")
} else {
    precondition(completions.isEmpty, "Canceled/reset session published old text")
}
if scenario == "reset" {
    cleaner.add("Hello world today")
    precondition(LlamaEngine.entered.wait(timeout: .now() + 2) == .success)
    LlamaEngine.release.signal()
    cleaner.waitUntilIdle()
    cleaner.willFinish()
    cleaner.finish { completions.append($0) }
    cleaner.waitUntilIdle()
    let deadline = Date().addingTimeInterval(0.3)
    while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(completions.count == 1 && completions[0] == "Hello world today")
}
cleaner.shutDown()
print("PASSED: \(scenario)")
'''

with tempfile.TemporaryDirectory(prefix='aloud-cleanup-lifecycle-') as tmp:
    root = Path(tmp)
    source = root / 'main.swift'
    source.write_text((ROOT / 'Sources/ReadAloud/TranscriptCleaner.swift').read_text() + '\n' + STUB)
    binary = root / 'cleanup-lifecycle'
    subprocess.run(['swiftc', '-O', str(source), '-o', str(binary)], check=True)
    for scenario in ('normal', 'cancel', 'reset', 'cancel-before-callback'):
        subprocess.run([str(binary), str(root / scenario), scenario], check=True, timeout=15)
