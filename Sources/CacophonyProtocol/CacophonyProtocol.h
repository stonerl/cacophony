#ifndef CACOPHONY_PROTOCOL_H
#define CACOPHONY_PROTOCOL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Four character code 'CACO' in little endian byte order.
#define CACOPHONY_MAGIC 0x4341434Fu
#define CACOPHONY_PROTOCOL_VERSION 1u
#define CACOPHONY_UDP_PORT 47833u

#define CACOPHONY_SAMPLE_RATE 48000u
#define CACOPHONY_CHANNELS 2u
#define CACOPHONY_PACKET_MAX_FRAMES 1024u

/// Float32, interleaved, native endian.
#define CACOPHONY_FORMAT_FLOAT32_INTERLEAVED 0u

/// Header prepended to every PCM packet.
///
/// The layout is naturally aligned (48 bytes) and is shared by the C++
/// driver and the Swift receiver.
typedef struct CacophonyPacketHeader {
    uint32_t magic;
    uint16_t version;
    uint16_t headerSize;
    uint64_t sequence;
    /// Device sample time of the first frame in this packet.
    uint64_t sampleTime;
    /// mach_absolute_time() when the packet was created.
    uint64_t hostTime;
    uint32_t sampleRate;
    uint32_t channels;
    uint32_t format;
    uint32_t frameCount;
} CacophonyPacketHeader;

#ifdef __cplusplus
static_assert(sizeof(CacophonyPacketHeader) == 48, "unexpected packet header layout");
#else
_Static_assert(sizeof(CacophonyPacketHeader) == 48, "unexpected packet header layout");
#endif

#ifdef __cplusplus
}
#endif

#endif // CACOPHONY_PROTOCOL_H
