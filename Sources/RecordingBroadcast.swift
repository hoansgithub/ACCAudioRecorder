//
//  RecordingBroadcast.swift
//  TalkNoteAI
//
//  Created by HoanNL on 17/11/25.
//
//  Internal broadcast mechanism for ACCAudioRecorder
//  Allows multiple subscribers to observe the same recording session
//

import Foundation
import os

/// Internal broadcast publisher for recording streams
/// Similar to PassthroughSubject - allows multiple concurrent subscribers
final class RecordingBroadcast<Element: Sendable>: @unchecked Sendable {

    // MARK: - Private State

    private struct State {
        var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
        var finished = false
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    // MARK: - Public API

    /// Creates a new stream that will receive all subsequent values
    nonisolated func stream(
        buffering: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: buffering) { [weak self] continuation in
            guard let self = self else {
                continuation.finish()
                return
            }

            let id = UUID()

            // Add continuation with lock
            let isFinished = lock.withLock { state -> Bool in
                if state.finished {
                    return true
                }
                state.continuations[id] = continuation
                return false
            }

            if isFinished {
                continuation.finish()
                return
            }

            // Set termination handler
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self = self else { return }
                _ = self.lock.withLock { state in
                    state.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Sends a value to all active subscribers
    nonisolated func send(_ value: Element) async {
        await Task.yield()

        let continuations = lock.withLock { state in
            Array(state.continuations.values)
        }

        for continuation in continuations {
            continuation.yield(value)
        }
    }

    /// Completes all active streams
    nonisolated func finish() async {
        await Task.yield()

        let continuations: [AsyncStream<Element>.Continuation]? = lock.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            let conts = Array(state.continuations.values)
            state.continuations.removeAll()
            return conts
        }

        guard let continuations = continuations else { return }

        for continuation in continuations {
            continuation.finish()
        }
    }

    /// Returns whether the broadcast has finished
    nonisolated func isFinished() -> Bool {
        lock.withLock { $0.finished }
    }

    /// Returns the current number of active subscribers
    nonisolated func subscriberCount() -> Int {
        lock.withLock { $0.continuations.count }
    }
}
