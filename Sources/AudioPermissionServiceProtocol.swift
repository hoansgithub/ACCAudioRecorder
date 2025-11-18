//
//  AudioPermissionServiceProtocol.swift
//  TalkNoteAI
//
//  Audio Permission Service
//

import Foundation
import AVFoundation

/// Represents the current state of audio recording permission
nonisolated public enum AudioPermissionStatus: Sendable {
    case notDetermined
    case granted
    case denied
    case restricted

    public var isGranted: Bool {
        return self == .granted
    }

    public static func == (lhs: AudioPermissionStatus, rhs: AudioPermissionStatus) -> Bool {
        switch (lhs, rhs) {
        case (.notDetermined, .notDetermined), (.granted, .granted), (.denied, .denied), (.restricted, .restricted):
            return true
        default:
            return false
        }
    }
}

/// Protocol for managing audio recording permissions
/// Provides both synchronous status checks and asynchronous observation of permission changes
public protocol AudioPermissionServiceProtocol: Actor {

    /// Current permission status (async getter)
    var currentStatus: AudioPermissionStatus { get async }

    /// Request audio recording permission from the user
    /// - Returns: Result containing the new permission status or an error
    func requestPermission() async -> Result<AudioPermissionStatus, Error>

    /// Check the current permission status without requesting
    /// - Returns: Current permission status
    func checkStatus() async -> AudioPermissionStatus

    /// Observe permission status changes
    /// - Returns: AsyncStream that emits permission status updates
    func observePermissionStatus() async -> AsyncStream<AudioPermissionStatus>

}
