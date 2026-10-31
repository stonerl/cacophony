import Foundation
import Synchronization

/// Single-producer single-consumer ring buffer of interleaved Float32 frames.
/// Writer: the tap IO thread. Reader: one output device's render thread.
final class RingBuffer: @unchecked Sendable {
    private let channelCount: Int
    private let capacityFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    init(channelCount: Int, capacityFrames: Int) {
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        storage = .allocate(capacity: channelCount * capacityFrames)
        storage.initialize(repeating: 0, count: channelCount * capacityFrames)
    }

    deinit {
        storage.deallocate()
    }

    var framesAvailable: Int {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .acquiring)
        return w - r
    }

    /// Writes interleaved frames. Drops the oldest data on overflow by
    /// advancing the read index (reader will just skip ahead).
    func write(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        precondition(frameCount <= capacityFrames)

        let w = writeIndex.load(ordering: .relaxed)
        discardOldestFrames(frameCount, writeIndex: w)

        let startSlot = w % capacityFrames
        let firstFrames = min(frameCount, capacityFrames - startSlot)
        storage.advanced(by: startSlot * channelCount)
            .update(from: samples, count: firstFrames * channelCount)
        if firstFrames < frameCount {
            storage.update(
                from: samples.advanced(by: firstFrames * channelCount),
                count: (frameCount - firstFrames) * channelCount
            )
        }
        writeIndex.store(w + frameCount, ordering: .releasing)
    }

    /// Writes silence, used to preserve timeline gaps from the driver.
    func writeSilence(frameCount: Int) {
        guard frameCount > 0 else { return }
        precondition(frameCount <= capacityFrames)

        let w = writeIndex.load(ordering: .relaxed)
        discardOldestFrames(frameCount, writeIndex: w)

        let startSlot = w % capacityFrames
        let firstFrames = min(frameCount, capacityFrames - startSlot)
        storage.advanced(by: startSlot * channelCount)
            .update(repeating: 0, count: firstFrames * channelCount)
        if firstFrames < frameCount {
            storage.update(repeating: 0, count: (frameCount - firstFrames) * channelCount)
        }
        writeIndex.store(w + frameCount, ordering: .releasing)
    }

    /// Advances the reader when the writer must overwrite buffered data.
    /// The CAS avoids losing a concurrent read-index update.
    private func discardOldestFrames(_ framesNeeded: Int, writeIndex w: Int) {
        var r = readIndex.load(ordering: .acquiring)
        var free = capacityFrames - (w - r)
        guard framesNeeded > free else { return }

        while true {
            let result = readIndex.compareExchange(
                expected: r,
                desired: r + (framesNeeded - free),
                successOrdering: .acquiringAndReleasing,
                failureOrdering: .acquiring
            )
            if result.exchanged { return }

            r = result.original
            free = capacityFrames - (w - r)
            guard framesNeeded > free else { return }
        }
    }

    /// Discards up to frameCount of the oldest buffered frames from the
    /// reader side. Safe while the writer runs; returns the frames dropped.
    @discardableResult
    func skip(frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        var current = readIndex.load(ordering: .acquiring)
        while true {
            let available = writeIndex.load(ordering: .acquiring) - current
            let dropped = min(frameCount, available)
            guard dropped > 0 else { return 0 }
            let result = readIndex.compareExchange(
                expected: current,
                desired: current + dropped,
                successOrdering: .releasing,
                failureOrdering: .acquiring
            )
            if result.exchanged { return dropped }
            current = result.original
        }
    }

    /// Discards buffered frames. Only safe while neither side is running.
    func reset() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }

    /// Reads up to frameCount interleaved frames; zero-fills the remainder.
    /// Returns the number of real frames delivered.
    @discardableResult
    func read(into output: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }

        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .acquiring)
        let available = min(frameCount, w - r)

        if available > 0 {
            let startSlot = r % capacityFrames
            let firstFrames = min(available, capacityFrames - startSlot)
            output.update(
                from: storage.advanced(by: startSlot * channelCount),
                count: firstFrames * channelCount
            )
            if firstFrames < available {
                output.advanced(by: firstFrames * channelCount)
                    .update(from: storage, count: (available - firstFrames) * channelCount)
            }
        }
        if available < frameCount {
            output.advanced(by: available * channelCount)
                .update(repeating: 0, count: (frameCount - available) * channelCount)
        }

        var current = r
        while true {
            let limit = writeIndex.load(ordering: .acquiring)
            let desired = min(current + available, max(current, limit))
            let result = readIndex.compareExchange(
                expected: current,
                desired: desired,
                successOrdering: .releasing,
                failureOrdering: .acquiring
            )
            if result.exchanged { break }
            current = result.original
        }
        return available
    }
}
