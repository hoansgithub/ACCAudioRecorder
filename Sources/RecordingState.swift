//
//  RecordingState.swift
//  TalkNoteAI
//
//  Created by HoanNL on 17/11/25.
//
//  Services Layer - Model
//

import Foundation

/// Domain model for recording state observation
/// Sendable struct allows usage across actor boundaries without isolation constraints
nonisolated public struct RecordingState: Sendable {
    public let isRecording: Bool
    public let isPaused: Bool
    public let currentDuration: TimeInterval?

    public init(isRecording: Bool, isPaused: Bool, currentDuration: TimeInterval?) {
        self.isRecording = isRecording
        self.isPaused = isPaused
        self.currentDuration = currentDuration
    }
}
