// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AVFoundation
import Speech
import MooseKit

/// Speech to text through the system recogniser, on this Mac only. If on-device recognition is not available for the
/// user's language it refuses rather than sending audio to a server.
@MainActor @Observable
final class Dictation {
    private(set) var active = false
    private(set) var text = ""
    private(set) var level: Float = 0
    private(set) var error: String?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async {
        guard !active else { return }
        error = nil; text = ""
        // Asking for the microphone without a usage string in Info.plist kills the process, so a bare `swift run` build says so instead.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            error = "Dictation works in the installed Moose app, not in a development build."; return
        }
        guard await Self.speechAllowed() else { error = "Allow Speech Recognition for Moose in System Settings → Privacy & Security."; return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { error = "Allow the Microphone for Moose in System Settings → Privacy & Security."; return }
        guard let rec = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(), rec.isAvailable else { error = "Speech recognition isn't available right now."; return }
        guard rec.supportsOnDeviceRecognition else {
            error = "On-device dictation isn't available for your language. Turn it on in System Settings → Keyboard → Dictation."; return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        let eng = AVAudioEngine()
        let input = eng.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { error = "No microphone found."; return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(req) { [weak self] l in Task { @MainActor in self?.level = l } })
        do { eng.prepare(); try eng.start() } catch let e { input.removeTap(onBus: 0); self.error = "Couldn't start the microphone."; AppLog.error(e, context: "dictation"); return }
        engine = eng; request = req; active = true
        task = rec.recognitionTask(with: req, resultHandler: Self.handler { [weak self] text, done in
            Task { @MainActor in
                guard let self, self.active else { return }
                if let text { self.text = text }
                if done { self.teardown() }
            }
        })
    }

    // Built outside the main actor on purpose: the system calls these on its own threads, and a closure that inherits the main actor would trap there.
    private nonisolated static func tap(_ req: SFSpeechAudioBufferRecognitionRequest, _ level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buf, _ in
            req.append(buf)
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            level(min(1, (n > 0 ? (sum / Float(n)).squareRoot() : 0) * 8))
        }
    }

    private nonisolated static func handler(_ f: @escaping @Sendable (String?, Bool) -> Void) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, err in f(result?.bestTranscription.formattedString, err != nil || result?.isFinal == true) }
    }

    /// Stops listening and returns what was heard.
    @discardableResult
    func stop() -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        request?.endAudio()
        teardown()
        return t
    }

    func cancel() { text = ""; teardown() }

    private func teardown() {
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0)
        task?.cancel()
        engine = nil; request = nil; task = nil; active = false; level = 0
    }

    private static func speechAllowed() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }
}
