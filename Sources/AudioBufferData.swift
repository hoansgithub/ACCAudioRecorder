//
//  AudioBufferData.swift
//  TalkNoteAI
//
//  Created by HoanNL on 16/11/25.
//

import Foundation
import AVFoundation
import os

public struct AudioBufferData: Sendable {
    public let data: Data
    public let frameLength: AVAudioFrameCount
    public let sampleRate: Double
    public let channelCount: AVAudioChannelCount
    public let timestamp: TimeInterval
    public let hostTime: UInt64

    public func toFloatArray() -> [Float]? {
        guard data.count % MemoryLayout<Float>.stride == 0 else {
            Logger(subsystem: "com.talknoteai.audiorecorder", category: "AudioBufferData")
                .error("Invalid audio buffer data size: \(data.count) bytes (must be multiple of \(MemoryLayout<Float>.stride))")
            return nil
        }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}
