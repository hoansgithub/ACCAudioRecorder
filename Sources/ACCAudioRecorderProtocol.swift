//
//  ACCAudioRecorderProtocol.swift
//  ACCAudioRecorder
//
//  Created by HoanNL on 16/11/25.
//

import Foundation

public protocol ACCAudioRecorderProtocol: Actor {
    // MARK: - Callback Handlers

    /// Called when an unrecoverable interruption occurs (after recording is automatically discarded)
    var onUnrecoverableInterruption: (@Sendable () async -> Void)? { get }
    func setOnUnrecoverableInterruption(_ handler: @escaping (@Sendable () async -> Void))

    /// Sets the time limit for recordings
    /// - Parameters:
    ///   - maxDuration: Maximum recording duration in seconds
    ///   - onTimeLimitReached: Optional closure called when the time limit is reached
    func setTimeLimit(maxDuration: TimeInterval, onTimeLimitReached: (@Sendable () async -> Void)?)

    /// Clears the time limit for recordings
    func clearTimeLimit()

    // MARK: - Recording Control

    /// Start a new recording session and return all streams (buffers, audio levels, state)
    func startRecording() async throws -> RecordingStreams

    /// Get current recording streams if a session is active (for reconnecting after view dismissal)
    /// Returns nil if no recording is in progress
    func getCurrentStreams() async -> RecordingStreams?

    /// Finish the recording session
    func finishRecording() async
    
    /// Temporarily pause the recording (can be resumed later)
    func pauseRecording() async
    
    /// Resume a paused recording
    func resumeRecording() async throws
    
    /// Discard the recording without saving
    func discardRecording() async
    
    // MARK: - Duration Tracking

    /// Get current recording duration
    func currentDuration() -> TimeInterval?

    /// Check if recording is currently paused
    func isPausedState() -> Bool
}
