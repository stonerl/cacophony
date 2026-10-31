// Cacophony HAL driver.
//
// Publishes a stereo output device and forwards the mixed output of all
// clients to a local UDP receiver. The menu bar app receives the PCM and
// sends it to AirPlay.

#include <aspl/Context.hpp>
#include <aspl/ControlRequestHandler.hpp>
#include <aspl/Device.hpp>
#include <aspl/Driver.hpp>
#include <aspl/IORequestHandler.hpp>
#include <aspl/Plugin.hpp>
#include <aspl/Stream.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include "../Sources/CacophonyProtocol/CacophonyProtocol.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <memory>

namespace {

constexpr UInt32 kSampleRate = CACOPHONY_SAMPLE_RATE;
constexpr UInt32 kChannelCount = CACOPHONY_CHANNELS;
constexpr UInt32 kBytesPerSample = sizeof(Float32);
constexpr UInt32 kBytesPerFrame = kChannelCount * kBytesPerSample;
constexpr UInt32 kMaxFramesPerPacket = CACOPHONY_PACKET_MAX_FRAMES;

class CacophonyIOHandler final : public aspl::ControlRequestHandler,
                                public aspl::IORequestHandler
{
public:
    OSStatus OnStartIO() override
    {
        socket_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (socket_ < 0) {
            return kAudioHardwareUnspecifiedError;
        }

        const int flags = fcntl(socket_, F_GETFL, 0);
        if (flags >= 0) {
            fcntl(socket_, F_SETFL, flags | O_NONBLOCK);
        }

        int sendBuffer = 1 << 20;
        setsockopt(socket_, SOL_SOCKET, SO_SNDBUF, &sendBuffer, sizeof(sendBuffer));

        sockaddr_in address{};
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_port = htons(CACOPHONY_UDP_PORT);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

        if (connect(socket_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0) {
            close(socket_);
            socket_ = -1;
            return kAudioHardwareUnspecifiedError;
        }

        return kAudioHardwareNoError;
    }

    void OnStopIO() override
    {
        if (socket_ >= 0) {
            close(socket_);
            socket_ = -1;
        }
    }

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override
    {
        (void)stream;
        (void)zeroTimestamp;

        if (socket_ < 0 || bytes == nullptr) {
            return;
        }

        const auto* cursor = static_cast<const UInt8*>(bytes);
        UInt32 remaining = bytesCount;
        UInt64 sampleTime = timestamp > 0 ? static_cast<UInt64>(timestamp) : 0;

        while (remaining >= kBytesPerFrame) {
            const UInt32 frames = std::min(remaining / kBytesPerFrame, kMaxFramesPerPacket);
            const UInt32 payloadBytes = frames * kBytesPerFrame;

            CacophonyPacketHeader header{};
            header.magic = CACOPHONY_MAGIC;
            header.version = CACOPHONY_PROTOCOL_VERSION;
            header.headerSize = static_cast<uint16_t>(sizeof(header));
            header.sequence = sequence_.fetch_add(1, std::memory_order_relaxed);
            header.sampleTime = sampleTime;
            header.hostTime = mach_absolute_time();
            header.sampleRate = kSampleRate;
            header.channels = kChannelCount;
            header.format = CACOPHONY_FORMAT_FLOAT32_INTERLEAVED;
            header.frameCount = frames;

            iovec iov[2] = {};
            iov[0].iov_base = &header;
            iov[0].iov_len = sizeof(header);
            iov[1].iov_base = const_cast<UInt8*>(cursor);
            iov[1].iov_len = payloadBytes;

            msghdr message{};
            message.msg_iov = iov;
            message.msg_iovlen = 2;

            (void)sendmsg(socket_, &message, MSG_DONTWAIT);

            cursor += payloadBytes;
            remaining -= payloadBytes;
            sampleTime += frames;
        }
    }

private:
    int socket_ = -1;
    std::atomic<uint64_t> sequence_{0};
};

std::shared_ptr<aspl::Driver> CreateDriver()
{
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters deviceParams;
    deviceParams.Name = "Cacophony";
    deviceParams.Manufacturer = "Toni Förster";
    deviceParams.DeviceUID = "CacophonyDevice";
    deviceParams.ModelUID = "Cacophony";
    deviceParams.CanBeDefault = true;
    deviceParams.CanBeDefaultForSystemSounds = true;
    deviceParams.SampleRate = kSampleRate;
    deviceParams.ChannelCount = kChannelCount;
    // Device latency stays 0: the AirPlay engine adds the default output
    // device's latency to the speakers' delay, so reporting it there would
    // push the speakers back by the same amount. See streamParams.Latency.
    deviceParams.Latency = 0;
    deviceParams.SafetyOffset = 0;
    deviceParams.EnableMixing = true;

    auto device = std::make_shared<aspl::Device>(context, deviceParams);

    aspl::StreamParameters streamParams;
    streamParams.Direction = aspl::Direction::Output;
    // The app holds the AirPlay stream this far behind the driver. Players
    // add stream latency to device latency, so this lets them delay video.
    streamParams.Latency = CACOPHONY_OUTPUT_LATENCY_FRAMES;
    streamParams.Format.mSampleRate = static_cast<Float64>(kSampleRate);
    streamParams.Format.mFormatID = kAudioFormatLinearPCM;
    streamParams.Format.mFormatFlags =
        kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    streamParams.Format.mBytesPerPacket = kBytesPerFrame;
    streamParams.Format.mFramesPerPacket = 1;
    streamParams.Format.mBytesPerFrame = kBytesPerFrame;
    streamParams.Format.mChannelsPerFrame = kChannelCount;
    streamParams.Format.mBitsPerChannel = kBytesPerSample * 8;
    streamParams.Format.mReserved = 0;

    device->AddStreamWithControlsAsync(streamParams);

    auto handler = std::make_shared<CacophonyIOHandler>();
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* CacophonyAudioEntryPoint(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    (void)allocator;

    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    static std::shared_ptr<aspl::Driver> driver = CreateDriver();
    return driver->GetReference();
}
