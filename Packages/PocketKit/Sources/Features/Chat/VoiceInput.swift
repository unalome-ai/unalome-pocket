import AVFoundation
import Foundation
import Observation
import Speech

/// Dictation into the composer with Apple's on-device `SpeechAnalyzer` + `SpeechTranscriber`.
///
/// Fails closed: it records only when on-device transcription is available and the speech model
/// for the language is already installed. It never falls back to `SFSpeechRecognizer` (which can
/// use Apple's servers) and never downloads speech assets itself, so no audio, text or request
/// leaves the device.
@MainActor
@Observable
public final class VoiceInput {
    public enum State: Equatable {
        case idle
        case preparing
        case recording
    }

    public private(set) var state: State = .idle
    /// Why voice input cannot be used right now, in plain words. Cleared on the next start.
    public private(set) var unavailableReason: String?

    /// Receives the dictated text (final plus the still-changing part) as it arrives.
    @ObservationIgnored public var onTranscript: (String) -> Void = { _ in }

    @ObservationIgnored private var finalized = ""
    @ObservationIgnored private var session: Session?

    /// One recording: the audio engine feeding the analyzer, and the task reading its results.
    private struct Session {
        let audio: AVAudioEngine
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>.Continuation
        let results: Task<Void, Never>
    }

    public init() {}

    /// The device can transcribe on-device at all (false in the Simulator and on older hardware).
    public static var isSupported: Bool {
        SpeechTranscriber.isAvailable
    }

    public var isRecording: Bool { state == .recording }

    public func toggle(locale: Locale = .current) {
        switch state {
        case .idle: Task { await start(locale: locale) }
        case .recording: Task { await stop() }
        case .preparing: break
        }
    }

    public func start(locale: Locale = .current) async {
        guard state == .idle else { return }
        state = .preparing
        unavailableReason = nil
        finalized = ""
        do {
            session = try await makeSession(locale: locale)
            state = .recording
        } catch {
            unavailableReason = (error as? VoiceInputError)?.message ?? error.localizedDescription
            state = .idle
            Self.deactivateAudioSession()
        }
    }

    /// Stops listening and waits for the last words to be transcribed.
    public func stop() async {
        guard let session else { return }
        self.session = nil
        session.audio.stop()
        session.audio.inputNode.removeTap(onBus: 0)
        session.input.finish()
        try? await session.analyzer.finalizeAndFinishThroughEndOfInput()
        await session.results.value
        Self.deactivateAudioSession()
        state = .idle
    }

    /// Stops at once, dropping anything not yet transcribed (the chat is closing).
    public func cancel() {
        guard let session else { return }
        self.session = nil
        session.audio.stop()
        session.audio.inputNode.removeTap(onBus: 0)
        session.input.finish()
        session.results.cancel()
        Task { await session.analyzer.cancelAndFinishNow() }
        Self.deactivateAudioSession()
        state = .idle
    }

    // MARK: Setup

    private func makeSession(locale: Locale) async throws -> Session {
        guard Self.isSupported else { throw VoiceInputError.notSupported }
        guard await AVAudioApplication.requestRecordPermission() else { throw VoiceInputError.microphoneDenied }

        let language = locale.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "")
            ?? locale.identifier
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceInputError.languageUnsupported(language)
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        // Only an installed model is used: downloading one would be a network request this app
        // does not make.
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw VoiceInputError.languageNotInstalled(language)
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceInputError.notSupported
        }

        try Self.activateAudioSession()
        let audio = AVAudioEngine()
        let inputFormat = audio.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw VoiceInputError.noMicrophone }
        guard let converter = BufferConverter(from: inputFormat, to: analyzerFormat) else {
            throw VoiceInputError.notSupported
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.receive(String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {
                self?.unavailableReason = "Voice input stopped: \(error.localizedDescription)"
            }
        }
        audio.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            if let converted = converter.convert(buffer) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
        do {
            try await analyzer.start(inputSequence: stream)
            audio.prepare()
            try audio.start()
        } catch {
            audio.inputNode.removeTap(onBus: 0)
            continuation.finish()
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return Session(audio: audio, analyzer: analyzer, input: continuation, results: results)
    }

    private func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized += text
            onTranscript(finalized)
        } else {
            onTranscript(finalized + text)
        }
    }

    private static func activateAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    private static func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// Plain-language reasons voice input is not available.
enum VoiceInputError: Error, Equatable {
    case notSupported
    case microphoneDenied
    case noMicrophone
    case languageUnsupported(String)
    case languageNotInstalled(String)

    var message: String {
        switch self {
        case .notSupported:
            "Voice input needs on-device speech recognition, which this device does not have."
        case .microphoneDenied:
            "Voice input needs the microphone. You can allow it in Settings › Privacy & Security › Microphone."
        case .noMicrophone:
            "No microphone is available."
        case .languageUnsupported(let language):
            "On-device speech recognition does not support \(language) yet."
        case .languageNotInstalled(let language):
            "On-device speech recognition for \(language) is not installed on this device, so voice input is off. "
                + "Nothing is sent to a server instead."
        }
    }
}

/// Converts microphone buffers to the analyzer's format. Called on the audio thread only.
private final class BufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter
        self.format = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
