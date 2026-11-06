#ifndef LX06_LG_STREAM_H
#define LX06_LG_STREAM_H

#include <stdint.h>

#define SYNC_DIRECTORY "/tmp/lx06-lg-native"
#define SYNC_SOCKET SYNC_DIRECTORY "/pcm.sock"
#define SYNC_READY SYNC_DIRECTORY "/ready"
#define SAMPLE_RATE 48000u
#define MAX_PACKET_FRAMES 1920u
#define PCM_MAGIC UINT32_C(0x4c473032)

struct stereo_frame {
    int16_t left;
    int16_t right;
};

struct pcm_packet {
    uint32_t magic;
    uint32_t stream;
    uint32_t offset;
    uint32_t frames;
    struct stereo_frame samples[MAX_PACKET_FRAMES];
};

#endif
