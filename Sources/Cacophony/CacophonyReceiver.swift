import Accelerate
import Darwin
import Foundation
import CacophonyProtocol

enum CacophonyReceiverError: Error, CustomStringConvertible {
    case socket(String)
    case bind(String)

    var description: String {
        switch self {
        case .socket(let message): return "socket: \(message)"
        case .bind(let message): return "bind: \(message)"
        }
    }
}

/// Receives the Cacophony driver's PCM packets on the loopback interface.
/// Packets are delivered on a dedicated receive thread.
final class CacophonyUDPReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var socketFD: Int32 = -1

    /// Called on the receive thread with the packet header and interleaved
    /// Float32 samples.
    var onPacket: ((CacophonyPacketHeader, [Float]) -> Void)?
    var onError: ((String) -> Void)?

    func start() throws {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        lock.unlock()

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw CacophonyReceiverError.socket(String(cString: strerror(errno)))
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var receiveBuffer: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(CACOPHONY_UDP_PORT).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw CacophonyReceiverError.bind(message)
        }

        lock.lock()
        socketFD = fd
        running = true
        lock.unlock()

        Thread.detachNewThread { [weak self] in
            self?.receiveLoop(fd: fd)
        }
    }

    func stop() {
        lock.lock()
        running = false
        let fd = socketFD
        lock.unlock()

        if fd >= 0 {
            shutdown(fd, SHUT_RD)
        }
    }

    deinit {
        stop()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func receiveLoop(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)

        while isRunning {
            let count = buffer.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, raw.count, 0)
            }

            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    continue
                }
                if isRunning {
                    onError?("recv: \(String(cString: strerror(errno)))")
                }
                break
            }

            guard count >= MemoryLayout<CacophonyPacketHeader>.size else { continue }

            let header = buffer.withUnsafeBytes { raw in
                raw.loadUnaligned(as: CacophonyPacketHeader.self)
            }

            guard header.magic == UInt32(CACOPHONY_MAGIC),
                  header.version == UInt16(CACOPHONY_PROTOCOL_VERSION),
                  header.headerSize == UInt16(MemoryLayout<CacophonyPacketHeader>.size),
                  header.format == UInt32(CACOPHONY_FORMAT_FLOAT32_INTERLEAVED),
                  header.channels == UInt32(CACOPHONY_CHANNELS),
                  header.sampleRate == UInt32(CACOPHONY_SAMPLE_RATE),
                  header.frameCount > 0,
                  header.frameCount <= UInt32(CACOPHONY_PACKET_MAX_FRAMES)
            else {
                continue
            }

            let sampleCount = Int(header.frameCount) * Int(header.channels)
            let payloadBytes = sampleCount * MemoryLayout<Float>.size
            guard count == Int(header.headerSize) + payloadBytes else { continue }

            let samples = buffer.withUnsafeBytes { raw -> [Float] in
                let start = raw.baseAddress!
                    .advanced(by: Int(header.headerSize))
                    .assumingMemoryBound(to: Float.self)
                return Array(UnsafeBufferPointer(start: start, count: sampleCount))
            }

            onPacket?(header, samples)
        }

        lock.lock()
        if socketFD == fd {
            socketFD = -1
        }
        lock.unlock()
        close(fd)
    }
}

/// Receive-side statistics used by the app.
final class CacophonyReceiveStats: @unchecked Sendable {
    private let lock = NSLock()
    private var packetCount = 0
    private var frameCount = 0
    private var gapCount = 0
    private var peak: Float = 0
    private var lastSequence: UInt64?

    func record(_ header: CacophonyPacketHeader, peak packetPeak: Float) {
        lock.lock()
        defer { lock.unlock() }

        packetCount += 1
        frameCount += Int(header.frameCount)

        if let lastSequence, header.sequence != lastSequence + 1 {
            gapCount += 1
        }

        lastSequence = header.sequence
        peak = max(peak, packetPeak)
    }

    func snapshot() -> (packets: Int, frames: Int, gaps: Int, peak: Float) {
        lock.lock()
        defer { lock.unlock() }
        let value = (packetCount, frameCount, gapCount, peak)
        peak = 0
        return value
    }
}

func peakAmplitude(of samples: [Float]) -> Float {
    var peak: Float = 0
    samples.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
        vDSP_maxmgv(base, 1, &peak, vDSP_Length(buffer.count))
    }
    return peak
}
