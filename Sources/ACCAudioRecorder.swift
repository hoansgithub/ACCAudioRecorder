//
//  ACCAudioRecorder.swift
//  ACCAudioRecorder
//
//  Created by HoanNL on 16/11/25.
//

import Foundation
import AVFoundation
import Accelerate

/// Streams returned from a recording session
/// Note: These are AsyncStreams created from RecordingBroadcast sources,
/// allowing multiple subscribers to observe the same recording session
/// Each call to getCurrentStreams() or startRecording() creates new independent subscriptions
public struct RecordingStreams: Sendable {
    /// Raw audio buffer data for processing (e.g., save to file, transcription)
    public let buffers: AsyncStream<AudioBufferData>

    /// Audio level history for waveform visualization (last 100 samples)
    /// Persists across view dismissals since it's stored in the singleton recorder
    /// Current audio level is the last element of this array
    public let audioLevelHistory: AsyncStream<[Float]>

    /// Recording state changes (isRecording, isPaused, currentDuration)
    public let state: AsyncStream<RecordingState>
    
    public init(buffers: AsyncStream<AudioBufferData>, audioLevelHistory: AsyncStream<[Float]>, state: AsyncStream<RecordingState>) {
        self.buffers = buffers
        self.audioLevelHistory = audioLevelHistory
        self.state = state
    }
}

public enum ACCAudioRecorderError: Error, LocalizedError {
    case recordingAlreadyInProgress
    case noActiveRecording
    case audioFormatCreationFailed
    case audioEngineStartFailed

    public var errorDescription: String? {
        switch self {
        case .recordingAlreadyInProgress:
            return "Recording is already in progress"
        case .noActiveRecording:
            return "No active recording to pause or resume"
        case .audioFormatCreationFailed:
            return "Failed to create audio format"
        case .audioEngineStartFailed:
            return "Failed to start audio engine"
        }
    }
}

public actor ACCAudioRecorder: ACCAudioRecorderProtocol {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let sampleRate: Double
        public let channelCount: UInt32
        public let bufferSize: AVAudioFrameCount
        public let audioSessionMode: AVAudioSession.Mode

        public init(
            sampleRate: Double = 44100,
            channelCount: UInt32 = 1,
            bufferSize: AVAudioFrameCount = 4096,
            audioSessionMode: AVAudioSession.Mode = .default
        ) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.bufferSize = bufferSize
            self.audioSessionMode = audioSessionMode
        }
    }

    private let configuration: Configuration

    // MARK: - Public Properties

    /// Handler called when an unrecoverable audio interruption occurs
    /// Set this to be notified when recording must be discarded due to system interruptions
    public var onUnrecoverableInterruption: (@Sendable () async -> Void)?

    // MARK: - Private State

    private var maxRecordingDuration: TimeInterval?
    private var onTimeLimitReached: (@Sendable () async -> Void)?

    // RecordingBroadcast sources - allow multiple subscribers to same recording session
    private var bufferBroadcast: RecordingBroadcast<AudioBufferData>?
    private var audioLevelHistoryBroadcast: RecordingBroadcast<[Float]>?
    private var stateBroadcast: RecordingBroadcast<RecordingState>?

    // Audio level history cache (persists across view dismissals)
    private var audioLevelHistory: [Float] = []
    private let maxHistorySize = 100

    // Duration update task for smooth progress updates
    private var durationUpdateTask: Task<Void, Never>?

    private var internalState: InternalState = .idle {
        didSet {
            // Yield state changes immediately (event-driven)
            yieldCurrentState()
        }
    }

    // Duration tracking
    private var accumulatedDuration: TimeInterval = 0
    private var currentSegmentStartTime: Date?

    private var audioEngine: AVAudioEngine?
    private var maxDurationTask: Task<Void, Never>?
    private var interruptionTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    deinit {
        durationUpdateTask?.cancel()
        maxDurationTask?.cancel()
        interruptionTask?.cancel()
        // Broadcasts will be cleaned up automatically
        debugPrint("\(Self.self) deallocated")
    }

    // MARK: - Public API - Configuration

    /// Sets the handler for unrecoverable interruptions
    /// - Parameter handler: Closure called when an unrecoverable interruption occurs
    public func setOnUnrecoverableInterruption(_ handler: @escaping @Sendable () async -> Void) {
        onUnrecoverableInterruption = handler
    }

    /// Sets the time limit for recordings
    /// - Parameters:
    ///   - maxDuration: Maximum recording duration in seconds
    ///   - handler: Closure called when the time limit is reached (optional)
    /// - Note: Call this before starting a recording. The handler will be invoked just before the recording finishes automatically.
    public func setTimeLimit(maxDuration: TimeInterval, onTimeLimitReached handler: (@Sendable () async -> Void)? = nil) {
        self.maxRecordingDuration = maxDuration
        self.onTimeLimitReached = handler
    }

    /// Clears the time limit for recordings
    public func clearTimeLimit() {
        self.maxRecordingDuration = nil
        self.onTimeLimitReached = nil
    }

    // MARK: - Public API - Recording Control

    /// Start a new recording session and return all streams
    public func startRecording() async throws -> RecordingStreams {
        log("Starting recording session")
        guard case .idle = internalState else {
            log("Recording already in progress", level: .error)
            throw ACCAudioRecorderError.recordingAlreadyInProgress
        }

        await cleanup()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .record,
            mode: configuration.audioSessionMode,
            options: []
        )
        try session.setActive(true)

        setupInterruptionHandling()

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Create RecordingBroadcast sources - allow multiple subscribers
        let bufferBroadcast = RecordingBroadcast<AudioBufferData>()
        let audioLevelHistoryBroadcast = RecordingBroadcast<[Float]>()
        let stateBroadcast = RecordingBroadcast<RecordingState>()

        self.bufferBroadcast = bufferBroadcast
        self.audioLevelHistoryBroadcast = audioLevelHistoryBroadcast
        self.stateBroadcast = stateBroadcast

        // Reset audio level history for new recording
        self.audioLevelHistory = []

        // Yield initial values
        await audioLevelHistoryBroadcast.send([])
        await stateBroadcast.send(RecordingState(isRecording: false, isPaused: false, currentDuration: nil))

        inputNode.installTap(
            onBus: 0,
            bufferSize: configuration.bufferSize,
            format: inputFormat
        ) { [weak self] buffer, time in
            guard let channelData = buffer.floatChannelData else { return }
            let channelDataValue = channelData.pointee
            let frameLength = Int(buffer.frameLength)

            // Calculate dB level on audio thread to avoid extra data copy later
            var rms: Float = 0
            vDSP_rmsqv(channelDataValue, 1, &rms, vDSP_Length(frameLength))
            let dbLevel = 20 * log10(max(rms, 0.000001))

            // Convert Float32 samples to Data for safe actor boundary crossing
            let data = Data(bytes: channelDataValue, count: frameLength * MemoryLayout<Float>.size)

            // Extract metadata before crossing actor boundary (these are Sendable types)
            let bufferFrameLength = buffer.frameLength     // Number of audio frames in this buffer (e.g., 4096)
            let sampleRate = buffer.format.sampleRate      // Samples per second (e.g., 44100 Hz)
            let channelCount = buffer.format.channelCount  // Number of audio channels (1=mono, 2=stereo)
            let hostTime = time.hostTime                   // High-precision timestamp from audio hardware

            // Process through actor - actor's serial executor guarantees FIFO order!
            Task { [weak self] in
                await self?.processAudioBuffer(
                    data: data,
                    frameLength: bufferFrameLength,
                    sampleRate: sampleRate,
                    channelCount: channelCount,
                    hostTime: hostTime,
                    dbLevel: dbLevel
                )
            }
        }

        do {
            try audioEngine.start()
            log("Audio engine started successfully")
        } catch {
            log("Failed to start audio engine: \(error)", level: .error)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw ACCAudioRecorderError.audioEngineStartFailed
        }

        let startTime = Date()

        // Initialize duration tracking
        accumulatedDuration = 0
        currentSegmentStartTime = startTime

        internalState = .recording(startTime: startTime)
        log("Recording session started")

        // Start duration update task for smooth progress
        startDurationUpdateTask()

        if let maxDuration = maxRecordingDuration {
            log("Max duration set to \(maxDuration)s", level: .debug)
            startMaxDurationTimer(
                maxDuration: maxDuration,
                onTimeLimitReached: onTimeLimitReached
            )
        }

        // Return streams from broadcasts - multiple subscribers can call this
        return RecordingStreams(
            buffers: bufferBroadcast.stream(),
            audioLevelHistory: audioLevelHistoryBroadcast.stream(buffering: .bufferingNewest(1)),
            state: stateBroadcast.stream(buffering: .bufferingNewest(1))
        )
    }

    /// Get current recording streams if a session is active
    /// Returns new stream subscriptions from the broadcasts
    /// Multiple calls create independent stream subscriptions to the same broadcast
    public func getCurrentStreams() async -> RecordingStreams? {
        guard let bufferBroadcast = bufferBroadcast,
              let audioLevelHistoryBroadcast = audioLevelHistoryBroadcast,
              let stateBroadcast = stateBroadcast else {
            return nil
        }

        // Create new stream subscriptions from the same broadcasts
        let streams = RecordingStreams(
            buffers: bufferBroadcast.stream(),
            audioLevelHistory: audioLevelHistoryBroadcast.stream(buffering: .bufferingNewest(1)),
            state: stateBroadcast.stream(buffering: .bufferingNewest(1))
        )

        // Broadcast current state after a brief delay to ensure subscribers are ready
        // This is necessary because stream subscription happens asynchronously
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
            await audioLevelHistoryBroadcast.send(self.audioLevelHistory)
            await stateBroadcast.send(self.computeCurrentState())
        }

        return streams
    }

    /// Finish the recording session
    public func finishRecording() async {
        log("Finishing recording session")
        guard let audioEngine = audioEngine else {
            log("No active audio engine to finish", level: .warning)
            return
        }

        maxDurationTask?.cancel()
        maxDurationTask = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        // Stop duration update task
        durationUpdateTask?.cancel()
        durationUpdateTask = nil

        // Reset duration tracking
        accumulatedDuration = 0
        currentSegmentStartTime = nil

        internalState = .idle
        log("Recording finished successfully")

        // Finish all broadcasts
        await bufferBroadcast?.finish()
        await audioLevelHistoryBroadcast?.finish()
        await stateBroadcast?.finish()

        bufferBroadcast = nil
        audioLevelHistoryBroadcast = nil
        stateBroadcast = nil

        // Clear audio level history
        audioLevelHistory = []

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log("Failed to deactivate audio session: \(error)", level: .error)
        }
    }

    /// Temporarily pause the recording (can be resumed later)
    public func pauseRecording() async {
        log("Pausing recording")
        guard case .recording(let startTime) = internalState, let audioEngine = audioEngine else {
            log("Cannot pause - not in recording state", level: .warning)
            return
        }

        // Stop duration updates while paused
        durationUpdateTask?.cancel()
        durationUpdateTask = nil

        // Accumulate the current segment duration before pausing
        if let segmentStart = currentSegmentStartTime {
            accumulatedDuration += Date().timeIntervalSince(segmentStart)
            currentSegmentStartTime = nil  // This triggers yieldCurrentState()
        }

        audioEngine.pause()
        maxDurationTask?.cancel()
        maxDurationTask = nil
        internalState = .paused(startTime: startTime)  // This also triggers yieldCurrentState()
        log("Recording paused at \(accumulatedDuration)s")
    }

    /// Resume a paused recording
    public func resumeRecording() async throws {
        log("Resuming recording")
        guard case .paused(let startTime) = internalState, let audioEngine = audioEngine else {
            log("Cannot resume - not in paused state", level: .warning)
            return
        }

        do {
            try audioEngine.start()

            // Start new segment timing from now
            currentSegmentStartTime = Date()  // This triggers yieldCurrentState()

            internalState = .recording(startTime: startTime)  // This also triggers yieldCurrentState()
            log("Recording resumed from \(accumulatedDuration)s")

            // Restart duration updates
            startDurationUpdateTask()

            // Restart max duration timer if configured
            // Timer will check actual currentDuration() against maxDuration
            if let maxDuration = maxRecordingDuration {
                startMaxDurationTimer(
                    maxDuration: maxDuration,
                    onTimeLimitReached: onTimeLimitReached
                )
            }
        } catch {
            log("Failed to resume audio engine: \(error)", level: .error)
            throw ACCAudioRecorderError.audioEngineStartFailed
        }
    }

    /// Discard the recording without saving
    public func discardRecording() async {
        log("Discarding recording session")
        guard let audioEngine = audioEngine else {
            log("No active audio engine to discard", level: .warning)
            return
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        // Stop all tasks
        durationUpdateTask?.cancel()
        durationUpdateTask = nil

        maxDurationTask?.cancel()
        maxDurationTask = nil

        // Reset duration tracking
        accumulatedDuration = 0
        currentSegmentStartTime = nil

        internalState = .idle

        // Finish all broadcasts
        await bufferBroadcast?.finish()
        await audioLevelHistoryBroadcast?.finish()
        await stateBroadcast?.finish()

        bufferBroadcast = nil
        audioLevelHistoryBroadcast = nil
        stateBroadcast = nil

        // Clear audio level history
        audioLevelHistory = []

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log("Failed to deactivate audio session: \(error)", level: .error)
        }

        self.audioEngine = nil
        log("Recording session discarded")
    }

    // MARK: - Public API - State Queries

    /// Get current recording duration
    public func currentDuration() -> TimeInterval? {
        guard internalState.isRecording else { return nil }

        switch internalState {
        case .idle:
            return nil
        case .recording:
            // When actively recording, return accumulated + current segment duration
            if let segmentStart = currentSegmentStartTime {
                return accumulatedDuration + Date().timeIntervalSince(segmentStart)
            }
            return accumulatedDuration
        case .paused:
            // When paused, return only accumulated duration (frozen)
            return accumulatedDuration
        }
    }

    /// Check if recording is currently paused
    public func isPausedState() -> Bool {
        return internalState.isPaused
    }
}

// MARK: - Private Types

private extension ACCAudioRecorder {

    enum InternalState {
        case idle
        case recording(startTime: Date)
        case paused(startTime: Date)

        var isRecording: Bool {
            switch self {
            case .idle:
                return false
            case .recording, .paused:
                return true
            }
        }

        var isPaused: Bool {
            if case .paused = self { return true }
            return false
        }

        var startTime: Date? {
            switch self {
            case .idle: return nil
            case .recording(let time), .paused(let time): return time
            }
        }
    }

    enum LogLevel {
        case info, warning, error, debug
    }
}

// MARK: - Private Methods - Audio Processing

private extension ACCAudioRecorder {

    func processAudioBuffer(
        data: Data,
        frameLength: AVAudioFrameCount,
        sampleRate: Double,
        channelCount: AVAudioChannelCount,
        hostTime: UInt64,
        dbLevel: Float
    ) async {
        guard !internalState.isPaused else { return }

        let timestamp = internalState.startTime.map { Date().timeIntervalSince($0) } ?? 0

        let audioBufferData = AudioBufferData(
            data: data,
            frameLength: frameLength,
            sampleRate: sampleRate,
            channelCount: channelCount,
            timestamp: timestamp,
            hostTime: hostTime
        )

        // Broadcast buffer to all subscribers
        await bufferBroadcast?.send(audioBufferData)

        // Update audio level history and broadcast (includes current level as last element)
        audioLevelHistory.append(dbLevel)
        if audioLevelHistory.count > maxHistorySize {
            audioLevelHistory.removeFirst()
        }
        await audioLevelHistoryBroadcast?.send(audioLevelHistory)

        // Note: State is NOT sent here - it's event-driven via didSet
    }
}

// MARK: - Private Methods - State Management

private extension ACCAudioRecorder {

    /// Send current state to all broadcast subscribers
    func yieldCurrentState() {
        Task { [weak self] in
            guard let self else { return }
            await stateBroadcast?.send(computeCurrentState())
        }
    }

    /// Compute current RecordingState from internal state
    func computeCurrentState() -> RecordingState {
        RecordingState(
            isRecording: internalState.isRecording,
            isPaused: internalState.isPaused,
            currentDuration: currentDuration()
        )
    }

    /// Start task to periodically update duration in state stream
    func startDurationUpdateTask() {
        durationUpdateTask?.cancel()
        durationUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms for smooth updates
                guard let self = self else { break }
                await self.stateBroadcast?.send(self.computeCurrentState())
            }
        }
    }
}

// MARK: - Private Methods - Lifecycle Management

private extension ACCAudioRecorder {

    func startMaxDurationTimer(
        maxDuration: TimeInterval,
        onTimeLimitReached: (@Sendable () async -> Void)?
    ) {
        maxDurationTask = Task { [weak self] in
            // Check every 100ms if we've exceeded the max duration
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

                guard let self = self else { break }
                guard await self.internalState.isRecording else { break }

                // Check actual current duration against limit
                if let currentDur = await self.currentDuration(),
                   currentDur >= maxDuration {
                    await self.log("Max duration reached (actual: \(currentDur)s, limit: \(maxDuration)s), finishing recording")
                    await onTimeLimitReached?()
                    await self.finishRecording()
                    break
                }
            }
        }
    }

    func cleanup() async {
        log("Cleaning up recording resources", level: .debug)

        durationUpdateTask?.cancel()
        durationUpdateTask = nil

        maxDurationTask?.cancel()
        maxDurationTask = nil

        interruptionTask?.cancel()
        interruptionTask = nil

        if let audioEngine = audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        audioEngine = nil

        // Finish all broadcasts
        await bufferBroadcast?.finish()
        await audioLevelHistoryBroadcast?.finish()
        await stateBroadcast?.finish()

        bufferBroadcast = nil
        audioLevelHistoryBroadcast = nil
        stateBroadcast = nil

        // Clear audio level history
        audioLevelHistory = []

        // Reset duration tracking
        accumulatedDuration = 0
        currentSegmentStartTime = nil

        internalState = .idle

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log("Failed to deactivate audio session during cleanup: \(error)", level: .error)
        }
    }
}

// MARK: - Private Methods - Interruption Handling

private extension ACCAudioRecorder {

    func setupInterruptionHandling() {
        interruptionTask?.cancel()

        interruptionTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance()
            )

            for await notification in notifications {
                guard !Task.isCancelled, let userInfo = notification.userInfo else { break }

                guard let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                    continue
                }

                let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt

                guard !Task.isCancelled else { break }
                await self?.handleInterruption(type: type, optionsValue: optionsValue)
            }
        }
    }

    func handleInterruption(type: AVAudioSession.InterruptionType, optionsValue: UInt?) async {
        switch type {
        case .began:
            if internalState.isRecording {
                log("Audio session interrupted", level: .warning)
                await pauseRecording()
            }

        case .ended:
            guard let optionsValue = optionsValue else {
                log("No interruption options - discarding recording", level: .warning)
                await discardRecording()
                await onUnrecoverableInterruption?()
                return
            }

            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

            if options.contains(.shouldResume) {
                log("Interruption ended - attempting to resume")

                do {
                    try AVAudioSession.sharedInstance().setActive(true)

                    if internalState.isPaused {
                        try await resumeRecording()
                    }
                } catch {
                    log("Failed to reactivate session or resume: \(error)", level: .error)
                    log("Discarding recording due to unrecoverable interruption", level: .warning)
                    await discardRecording()
                    await onUnrecoverableInterruption?()
                }
            } else {
                log("System does not recommend resuming - discarding", level: .warning)
                await discardRecording()
                await onUnrecoverableInterruption?()
            }

        @unknown default:
            log("Unknown interruption type received", level: .warning)
            break
        }
    }
}

// MARK: - Private Methods - Logging

private extension ACCAudioRecorder {

    var logger: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    func log(_ message: String, level: LogLevel = .info) {
        guard logger else { return }
        let prefix: String
        switch level {
        case .info: prefix = "ℹ️"
        case .warning: prefix = "⚠️"
        case .error: prefix = "❌"
        case .debug: prefix = "🔍"
        }
        print("\(prefix) [ACCAudioRecorder] \(message)")
    }
}
