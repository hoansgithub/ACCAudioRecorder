//
//  AudioPermissionService.swift
//  ACCAudioRecorder
//
//  Created by HoanNL.
//

import Foundation
import AVFoundation

/// Concrete implementation of AudioPermissionServiceProtocol
/// Manages audio recording permissions with observation capabilities
public actor AudioPermissionService: AudioPermissionServiceProtocol {

    // MARK: - Properties

    private var _currentStatus: AudioPermissionStatus

    public var currentStatus: AudioPermissionStatus {
        get async {
            _currentStatus
        }
    }
    
    // MARK: - Initialization
    
    public init() {
        // Initialize with current system permission status
        self._currentStatus = Self.mapAVAudioSessionPermission(
            AVAudioSession.sharedInstance().recordPermission
        )
    }
    
    // MARK: - Public Methods
    
    public func requestPermission() async -> Result<AudioPermissionStatus, Error> {
        let currentAVStatus = AVAudioSession.sharedInstance().recordPermission
        
        // If already determined, return current status
        if currentAVStatus != .undetermined {
            let status = Self.mapAVAudioSessionPermission(currentAVStatus)
            updateStatus(status)
            return .success(status)
        }
        
        // Request permission from user
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        let newStatus: AudioPermissionStatus = granted ? .granted : .denied
        updateStatus(newStatus)

        print("✅ Audio recording permission requested: \(newStatus)")
        return .success(newStatus)
    }
    
    public func checkStatus() async -> AudioPermissionStatus {
        let avStatus = AVAudioSession.sharedInstance().recordPermission
        let status = Self.mapAVAudioSessionPermission(avStatus)

        // Update internal status if changed
        if status != _currentStatus {
            updateStatus(status)
        }

        return status
    }
    
    public func observePermissionStatus() async -> AsyncStream<AudioPermissionStatus> {
        let currentStatus = _currentStatus

        return AsyncStream<AudioPermissionStatus> { continuation in
            // Yield current status once and finish
            continuation.yield(currentStatus)
            continuation.finish()
        }
    }

    // MARK: - Private Methods

    /// Update the current status
    private func updateStatus(_ newStatus: AudioPermissionStatus) {
        guard newStatus != _currentStatus else { return }

        _currentStatus = newStatus

        print("🔍 Audio permission status updated: \(newStatus)")
    }

    /// Map AVAudioSession permission to our permission status enum
    private static func mapAVAudioSessionPermission(_ permission: AVAudioSession.RecordPermission) -> AudioPermissionStatus {
        switch permission {
        case .undetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .granted:
            return .granted
        @unknown default:
            return .restricted
        }
    }
    
    // MARK: - Deinitialization

    deinit {
        debugPrint("\(Self.self) deinited")
    }
}
