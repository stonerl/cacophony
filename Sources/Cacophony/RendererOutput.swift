import CacophonyRouting
import AVFoundation
import CoreMedia
import Foundation
import Synchronization

/// Plays a live interleaved Float32 stream through AVSampleBufferAudioRenderer,
/// which is the pipeline that can be attached to an (private) AVOutputContext
/// for AirPlay 2 group playback.
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

    /// Frames to accumulate before starting the clock (AirPlay needs preroll).
    private let prerollFrames: Int
    private let chunkFrames = 4800

    init(format: AVAudioFormat, ring: RingBuffer, prerollSeconds: Double = 0.5) {
        self.format = format
        self.ring = ring
        self.prerollFrames = Int(format.sampleRate * prerollSeconds)
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
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
        self.timer = timer
    }

    private func pump() {
        if !started {
            guard ring.framesAvailable >= prerollFrames else { return }
            synchronizer.setRate(1.0, time: .zero)
            started = true
        }
        if started, CACRendererIsReady(renderer), ring.framesAvailable == 0 {
            ringEmptyTicks.store(ringEmptyTicks.load(ordering: .relaxed) + 1, ordering: .relaxed)
        }
        while CACRendererIsReady(renderer), ring.framesAvailable >= chunkFrames {
            guard let sampleBuffer = makeSampleBuffer(frameCount: chunkFrames) else { return }
            CACRendererEnqueue(renderer, sampleBuffer)
        }
    }

    private func makeSampleBuffer(frameCount: Int) -> CMSampleBuffer? {
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

        ring.read(
            into: UnsafeMutableRawPointer(dataPointer).assumingMemoryBound(to: Float.self),
            frameCount: frameCount
        )

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
