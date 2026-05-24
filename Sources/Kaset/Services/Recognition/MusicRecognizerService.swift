import Foundation
import Observation

// MARK: - MusicRecognizerService

@MainActor
@Observable
final class MusicRecognizerService {
    private let logger = DiagnosticsLogger.ai

    // Path to external recognizer binary or CLI. Update via settings if needed.
    var recognizerPath: String = "/usr/local/bin/music-recognizer"
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private(set) var isRunning: Bool = false
    private(set) var lastResult: String?

    func startRecognition() {
        guard !self.isRunning else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: self.recognizerPath) else {
            self.logger.error("Music recognizer binary not found at \(self.recognizerPath)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: self.recognizerPath)
        process.arguments = [] // CLI args may be added later

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            self.logger.error("Failed to start recognizer: \(error.localizedDescription)")
            return
        }

        self.process = process
        self.stdoutHandle = outPipe.fileHandleForReading
        self.isRunning = true

        self.stdoutHandle?.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                Task { @MainActor in
                    self.handleOutputLine(line)
                }
            }
        }

        self.logger.info("Started music recognizer at \(self.recognizerPath)")
    }

    func stopRecognition() {
        guard self.isRunning else { return }
        self.stdoutHandle?.readabilityHandler = nil
        if let proc = process {
            proc.terminate()
            proc.waitUntilExit()
        }
        self.process = nil
        self.stdoutHandle = nil
        self.isRunning = false
        self.logger.info("Stopped music recognizer")
    }

    private func handleOutputLine(_ line: String) {
        // Best-effort: recognizer CLI may output JSON or plain text. Try JSON first.
        if let data = line.data(using: .utf8) {
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let title = json["title"] as? String
            {
                self.lastResult = title
                self.logger.info("Recognizer result: \(title)")
                // Post a notification for other components
                NotificationCenter.default.post(name: .musicRecognizerDidRecognize, object: self, userInfo: json)
                return
            }
        }

        // Fallback: treat raw line as result
        self.lastResult = line
        self.logger.info("Recognizer raw output: \(line)")
        NotificationCenter.default.post(name: .musicRecognizerDidRecognize, object: self, userInfo: ["raw": line])
    }
}

extension Notification.Name {
    static let musicRecognizerDidRecognize = Notification.Name("musicRecognizer.didRecognize")
}
