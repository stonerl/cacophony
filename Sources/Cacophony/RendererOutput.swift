import CacophonyRouting
import AVFoundation
import CoreMedia
import Foundation
import Synchronization

/// How much audio sits between the driver and the speakers.
struct LatencySnapshot {
    /// Seconds of audio waiting in the ring buffer.
    let ring: Double
    /// Seconds the enqueued timeline runs ahead of the synchronizer clock.
    let lead: Double

    /// Seconds between the driver producing audio and the speakers playing it.
    var total: Double { ring + lead }
}

/// Plays a live interleaved Float32 stream through AVSampleBufferAudioRenderer,
/// which is the pipeline that can be attached to an (private) AVOutputContext
/// for AirPlay 2 group playback.
///
/// AirPlay plays each sample at its presentation time, so the delay from the
/// driver to the speakers is how far the enqueued timeline runs ahead of the
/// synchronizer clock. The output holds that lead at `targetLead`: silence
/// covers gaps in the driver stream, and audio that would push the lead past
/// the target is dropped. The driver reports the same delay to macOS, which
/// is what lets players keep video in sync.
final class RendererOutput {
    let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let ring: RingBuffer
    private let format: AVAudioFormat
    private let queue = DispatchQueue(label: "cacophony.renderer")
    private var timer: DispatchSourceTimer?
    private var formatDescription: CMAudioFormatDescription?
    private let framesEnqueued = Atomic<Int64>(0)
    private var started = false

    /// Frames handed to the renderer. Used to detect a stuck connection.
    var enqueuedFrames: Int64 { framesEnqueued.load(ordering: .relaxed) }

    /// Timer ticks that found the renderer ready and the source ring empty.
    let ringEmptyTicks = Atomic<Int>(0)
    /// Silence frames inserted to cover gaps in the driver stream.
    let paddedFrames = Atomic<Int>(0)
    /// Driver frames dropped to keep the delay from growing.
    let droppedFrames = Atomic<Int>(0)

    /// Seconds the stream is held ahead of the clock.
    let targetLead: Double

    private let chunkFrames = 960  // 20 ms
    private let prerollFrames: Int
    /// Ring depth beyond which buffered audio is dropped.
    private let maxBacklogFrames: Int

    /// Lead slack before live audio is held back.
    private static let leadHeadroom = 0.02
    /// Lead shortfall before silence is inserted. Larger than one pump
    /// interval so normal timer jitter never inserts silence into audio.
    private static let gapThreshold = 0.06

    init(format: AVAudioFormat, ring: RingBuffer, targetLead: Double) {
        self.format = format
        self.ring = ring
        self.targetLead = targetLead
        self.prerollFrames = max(chunkFrames, Int(format.sampleRate * targetLead))
        self.maxBacklogFrames = Int(format.sampleRate * 0.25)
    }

    func start() throws {
        var asbd = format.streamDescription.pointee
        var description: CMAudioFormatDescription?
        try check(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            ),
            "CMAudioFormatDescriptionCreate"
        )
        formatDescription = description

        CACRendererAddToSynchronizer(synchronizer, renderer)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
        self.timer = timer
    }

    func latencySnapshot() -> LatencySnapshot {
        LatencySnapshot(
            ring: Double(ring.framesAvailable) / format.sampleRate,
            lead: currentLead()
        )
    }

    private func currentLead() -> Double {
        let clock = CMTimeGetSeconds(synchronizer.currentTime())
        let enqueued = Double(framesEnqueued.load(ordering: .relaxed)) / format.sampleRate
        return enqueued - (clock.isFinite ? clock : 0)
    }

    private func pump() {
        if !started {
            // Preroll one full lead so the stream starts at the target delay.
            guard ring.framesAvailable >= prerollFrames else { return }
            synchronizer.setRate(1.0, time: .zero)
            started = true
        }

        let chunkSeconds = Double(chunkFrames) / format.sampleRate
        var lead = currentLead()

        if CACRendererIsReady(renderer), ring.framesAvailable == 0 {
            ringEmptyTicks.store(ringEmptyTicks.load(ordering: .relaxed) + 1, ordering: .relaxed)
        }

        // Live audio, up to the target lead. If the clock stalls, audio
        // backs up in the ring instead of stretching the delay.
        while lead < targetLead + Self.leadHeadroom,
              CACRendererIsReady(renderer),
              ring.framesAvailable >= chunkFrames {
            guard enqueue(fromRing: true) else { return }
            lead += chunkSeconds
        }

        let backlog = ring.framesAvailable
        if backlog > maxBacklogFrames {
            let dropped = ring.skip(frameCount: backlog - chunkFrames)
            droppedFrames.store(droppedFrames.load(ordering: .relaxed) + dropped, ordering: .relaxed)
        }

        // The driver went quiet (device IO paused). Keep the timeline ahead
        // of the clock with silence so audio resumes at the same delay.
        if ring.framesAvailable < chunkFrames, lead < targetLead - Self.gapThreshold {
            while lead < targetLead - Self.leadHeadroom, CACRendererIsReady(renderer) {
                guard enqueue(fromRing: false) else { return }
                lead += chunkSeconds
                paddedFrames.store(paddedFrames.load(ordering: .relaxed) + chunkFrames, ordering: .relaxed)
            }
        }
    }

    /// Enqueues one chunk, from the ring or as silence.
    private func enqueue(fromRing: Bool) -> Bool {
        guard let sampleBuffer = makeSampleBuffer(frameCount: chunkFrames, fromRing: fromRing) else {
            return false
        }
        CACRendererEnqueue(renderer, sampleBuffer)
        return true
    }

    private func makeSampleBuffer(frameCount: Int, fromRing: Bool) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }
        let channelCount = Int(format.channelCount)
        let byteCount = frameCount * channelCount * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr,
        let dataPointer,
        lengthAtOffset >= byteCount
        else { return nil }

        let samples = UnsafeMutableRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
        if fromRing {
            ring.read(into: samples, frameCount: frameCount)
        } else {
            samples.update(repeating: 0, count: frameCount * channelCount)
        }

        var sampleBuffer: CMSampleBuffer?
        let pts = CMTime(
            value: framesEnqueued.load(ordering: .relaxed),
            timescale: CMTimeScale(format.sampleRate)
        )
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        framesEnqueued.store(
            framesEnqueued.load(ordering: .relaxed) + Int64(frameCount),
            ordering: .relaxed
        )
        return sampleBuffer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {}  // let an in-flight pump finish before the ring is reused
        synchronizer.setRate(0, time: .zero)
        CACRendererStopRequesting(renderer)
        CACRendererFlush(renderer)
    }
}
