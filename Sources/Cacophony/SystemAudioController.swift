import CacophonyRouting
import AVFoundation
import Darwin
import Foundation
import Synchronization
import CacophonyProtocol

/// Receives system audio from the Cacophony HAL driver and streams it to the
/// AirPlay output context selected in the system picker.
final class SystemAudioController: @unchecked Sendable {
    let context: NSObject

    private let format: AVAudioFormat
    private let ring: RingBuffer
    private let receiver = CacophonyUDPReceiver()
    private let stateLock = NSLock()
    private var lastPacket: TimeInterval = 0
    private var lastAudible: TimeInterval = 0
    private var askedForSpeakers = false
    private var output: RendererOutput?
    private var timer: Timer?
    private var receiverRunning = false
    private var lastStatsLog: TimeInterval = 0
    private var expectedSampleTime: UInt64?
    private var retryNotBefore: TimeInterval = 0
    private var previousHasSpeakers = false
    private let connectionTimeout: TimeInterval = 10
    private var lastEnqueuedFrames: Int64 = 0
    private var lastEnqueuedProgressAt: TimeInterval = 0
    private var latePacketDrops = 0

    private static let hostTimeScale: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    private(set) var lastError: String?
    private let receiveStats = CacophonyReceiveStats()

    /// Called on the main thread when the stream starts or stops.
    var onChange: (() -> Void)?

    /// Called on the main thread when system audio is playing but no AirPlay
    /// speakers are selected.
    var onNeedsSpeakers: (() -> Void)?

    /// Called on the main thread when an active AirPlay route stops making
    /// progress and the output context needs to be replaced.
    var onConnectionFailure: ((String) -> Void)?

    init(context: NSObject) {
        self.context = context
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(CACOPHONY_SAMPLE_RATE),
            channels: AVAudioChannelCount(CACOPHONY_CHANNELS),
            interleaved: true
        ) else {
            fatalError("could not create Cacophony audio format")
        }
        self.format = format
        self.ring = RingBuffer(
            channelCount: Int(CACOPHONY_CHANNELS),
            capacityFrames: Int(CACOPHONY_SAMPLE_RATE) * 2
        )
    }

    deinit {
        stop()
    }

    var isStreaming: Bool { output != nil }

    var routedDeviceNames: [String] {
        CACContextOutputDevices(context).compactMap {
            CACDeviceProperty($0, "deviceName") as? String
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !receiverRunning else { return }

        do {
            try receiver.start()
        } catch {
            lastError = "\(error)"
            alog("Cacophony receiver failed: \(error)")
            onChange?()
            return
        }

        receiver.onPacket = { [weak self] header, samples in
            self?.handle(header, samples: samples)
        }
        receiver.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.lastError = message
                self?.onChange?()
            }
        }

        receiverRunning = true
        lastError = nil
        stateLock.lock()
        expectedSampleTime = nil
        stateLock.unlock()
        alog("Cacophony receiver listening on udp 127.0.0.1:\(CACOPHONY_UDP_PORT)")

        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.25
        self.timer = timer
        tick()
        onChange?()
    }

    func stop() {
        guard receiverRunning || output != nil else { return }

        timer?.invalidate()
        timer = nil
        receiver.stop()
        receiverRunning = false
        stopOutput(reason: "stopped")
        retryNotBefore = 0
        previousHasSpeakers = false
        stateLock.lock()
        expectedSampleTime = nil
        stateLock.unlock()
        ring.reset()
        alog("Cacophony receiver stopped")
        onChange?()
    }

    // MARK: Receive

    private func preserveTimeline(_ header: CacophonyPacketHeader) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let expected = expectedSampleTime {
            if header.sampleTime > expected {
                let gap = header.sampleTime - expected
                if gap <= UInt64(CACOPHONY_SAMPLE_RATE) {
                    ring.writeSilence(frameCount: Int(gap))
                    alog("packet timeline gap: \(gap) frames")
                } else {
                    ring.reset()
                    alog("packet timeline reset after \(gap) frames")
                }
            } else if header.sampleTime < expected {
                let behind = expected - header.sampleTime
                if behind <= UInt64(CACOPHONY_SAMPLE_RATE) {
                    return false
                }
                ring.reset()
                alog("packet timeline reset after \(behind) frames")
            }
        }
        expectedSampleTime = header.sampleTime + UInt64(header.frameCount)
        return true
    }

    private func handle(_ header: CacophonyPacketHeader, samples: [Float]) {
        let now = ProcessInfo.processInfo.systemUptime

        if header.hostTime > 0 {
            let ageTicks = mach_absolute_time() - header.hostTime
            let ageSeconds = Double(ageTicks) * Self.hostTimeScale
            if ageSeconds > 0.5 {
                latePacketDrops += 1
                if latePacketDrops == 1 || latePacketDrops % 100 == 0 {
                    alog("dropped late packet: age=\(String(format: "%.3f", ageSeconds))s total=\(latePacketDrops)")
                }
                return
            }
        }

        let peak = peakAmplitude(of: samples)

        stateLock.lock()
        lastPacket = now
        if peak > 0.0001 {
            lastAudible = now
        }
        stateLock.unlock()

        receiveStats.record(header, peak: peak)

        guard preserveTimeline(header) else { return }

        // Always buffer. History is dropped when the renderer starts.
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
            ring.write(base, frameCount: buffer.count / Int(header.channels))
        }
    }

    // MARK: Reconcile

    func tick() {
        guard receiverRunning else { return }

        let now = ProcessInfo.processInfo.systemUptime

        stateLock.lock()
        let packetAge = lastPacket > 0 ? now - lastPacket : .infinity
        let audibleAge = lastAudible > 0 ? now - lastAudible : .infinity
        stateLock.unlock()

        if let output, CACRendererFailed(output.renderer) {
            lastError = CACRendererErrorMessage(output.renderer) ?? "renderer failed"
            alog("AirPlay renderer failed: \(lastError ?? "?")")
            stopOutput(reason: "renderer failed")
            onConnectionFailure?(lastError ?? "AirPlay renderer failed")
            onChange?()
            return
        }

        if let output {
            let frames = output.enqueuedFrames
            if frames > lastEnqueuedFrames {
                lastEnqueuedFrames = frames
                lastEnqueuedProgressAt = now
            }
        }

        // No packets for a while: release the AirPlay session.
        if output != nil, packetAge > 5 {
            stopOutput(reason: "no driver packets")
            onChange?()
            return
        }

        let hasSpeakers = !CACContextOutputDevices(context).isEmpty
        if hasSpeakers, !previousHasSpeakers {
            retryNotBefore = 0
        }
        previousHasSpeakers = hasSpeakers

        guard hasSpeakers else {
            if output != nil {
                stopOutput(reason: "no speakers")
                onChange?()
            }
            if audibleAge < 2, !askedForSpeakers {
                askedForSpeakers = true
                alog("system audio is playing with no speakers selected")
                onNeedsSpeakers?()
            } else if audibleAge > 30 {
                askedForSpeakers = false
            }
            return
        }

        if output != nil,
           audibleAge < 2,
           now - lastEnqueuedProgressAt >= connectionTimeout {
            let names = routedDeviceNames.joined(separator: " + ")
            alog("AirPlay connection stalled after \(Int(connectionTimeout))s: \(names)")
            lastError = "Could not connect to AirPlay speaker"
            stopOutput(reason: "connection stalled")
            retryNotBefore = now + connectionTimeout
            onConnectionFailure?(lastError ?? "Could not connect to AirPlay speaker")
            onChange?()
            return
        }

        if output == nil, audibleAge < 2, now >= retryNotBefore {
            startOutput()
            onChange?()
        }

        if output != nil, audibleAge > 30 {
            stopOutput(reason: "silence")
            askedForSpeakers = false
            onChange?()
        }

        if let output, now - lastStatsLog >= 10 {
            lastStatsLog = now
            let snapshot = receiveStats.snapshot()
            alog("stats packets=\(snapshot.packets) frames=\(snapshot.frames) gaps=\(snapshot.gaps) peak=\(String(format: "%.3f", snapshot.peak)) ringEmpty=\(output.ringEmptyTicks.load(ordering: .relaxed)) enqueued=\(output.enqueuedFrames)")
        }
    }

    private func startOutput() {
        ring.reset()
        stateLock.lock()
        expectedSampleTime = nil
        stateLock.unlock()
        do {
            let output = RendererOutput(format: format, ring: ring)
            try output.start()
            if CACRendererSetOutputContext(output.renderer, context) {
                lastError = nil
            } else {
                lastError = "renderer setOutputContext: unavailable"
            }
            self.output = output
            lastEnqueuedFrames = 0
            lastEnqueuedProgressAt = ProcessInfo.processInfo.systemUptime
            alog("Cacophony streaming to \(routedDeviceNames.joined(separator: " + "))")
        } catch {
            lastError = "\(error)"
            alog("Cacophony renderer start failed: \(error)")
        }
    }

    private func stopOutput(reason: String) {
        stateLock.lock()
        expectedSampleTime = nil
        stateLock.unlock()
        guard let output else { return }
        output.stop()
        self.output = nil
        ring.reset()
        alog("Cacophony streaming stopped: \(reason)")
    }
}
