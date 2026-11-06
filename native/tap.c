#define _GNU_SOURCE
#include "ladspa.h"
#include "stream.h"

#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

enum port { LEFT_IN, RIGHT_IN, LEFT_OUT, RIGHT_OUT, DELAY_MS, PORT_COUNT };
enum { MAX_DELAY_MS = 750 };

struct tap {
    LADSPA_Data *port[PORT_COUNT];
    unsigned long rate;
    unsigned int ring_pos;
    unsigned int last_delay;
    unsigned int missed;
    uint32_t offset;
    float wet;
    int started;
    int socket;
    struct sockaddr_un peer;
    struct pcm_packet packet;
    float delay[SAMPLE_RATE * MAX_DELAY_MS / 1000u][2];
};

static LADSPA_Handle instantiate(const LADSPA_Descriptor *descriptor, unsigned long rate) {
    (void)descriptor;
    struct tap *tap = calloc(1, sizeof(*tap));
    if (!tap)
        return NULL;
    tap->rate = rate;
    tap->socket = socket(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    tap->peer.sun_family = AF_UNIX;
    strcpy(tap->peer.sun_path, SYNC_SOCKET);
    tap->packet.magic = PCM_MAGIC;
    return tap;
}

static void connect_port(LADSPA_Handle handle, unsigned long port, LADSPA_Data *data) {
    struct tap *tap = handle;
    if (port < PORT_COUNT)
        tap->port[port] = data;
}

static void activate(LADSPA_Handle handle) {
    struct tap *tap = handle;
    struct timespec now = {0};
    clock_gettime(CLOCK_MONOTONIC, &now);
    tap->packet.stream = (uint32_t)(uintptr_t)tap ^ (uint32_t)now.tv_nsec ^ (uint32_t)getpid();
    tap->offset = 0;
    tap->missed = 0;
    tap->started = 0;
    tap->last_delay = 0;
}

static int16_t to_pcm(float sample) {
    if (!isfinite(sample))
        return 0;
    if (sample >= 1.0f)
        return INT16_MAX;
    if (sample <= -1.0f)
        return INT16_MIN;
    return (int16_t)(sample * 32768.0f);
}

static unsigned int send_pcm(struct tap *tap, unsigned long frames) {
    if (tap->socket < 0 || tap->rate != SAMPLE_RATE)
        return 0;
    unsigned int sent = 0;
    for (unsigned long pos = 0; pos < frames; ) {
        const unsigned long remaining = frames - pos;
        const unsigned int count = remaining > MAX_PACKET_FRAMES ? MAX_PACKET_FRAMES : remaining;
        tap->packet.offset = tap->offset;
        tap->packet.frames = count;
        for (unsigned int i = 0; i < count; ++i) {
            tap->packet.samples[i].left = to_pcm(tap->port[LEFT_IN][pos + i]);
            tap->packet.samples[i].right = to_pcm(tap->port[RIGHT_IN][pos + i]);
        }
        const size_t bytes = offsetof(struct pcm_packet, samples) + count * sizeof(struct stereo_frame);
        if (sendto(tap->socket, &tap->packet, bytes, MSG_DONTWAIT | MSG_NOSIGNAL,
                   (const struct sockaddr *)&tap->peer, sizeof(tap->peer)) == (ssize_t)bytes)
            sent += count;
        tap->offset += count;
        pos += count;
    }
    return sent;
}

static void run(LADSPA_Handle handle, unsigned long frames) {
    struct tap *tap = handle;
    if (!frames)
        return;
    const float milliseconds = *tap->port[DELAY_MS];
    const unsigned int wanted_delay =
        tap->rate == SAMPLE_RATE && milliseconds >= 0 && milliseconds <= MAX_DELAY_MS
        ? (unsigned int)(milliseconds * (SAMPLE_RATE / 1000u)) : 0;
    if (wanted_delay != tap->last_delay || !tap->started) {
        memset(tap->delay, 0, wanted_delay * sizeof(tap->delay[0]));
        tap->last_delay = wanted_delay;
        tap->ring_pos = 0;
    }

    const unsigned int sent = send_pcm(tap, frames);
    tap->missed = sent ? 0 : (tap->missed < 100 ? tap->missed + 1 : tap->missed);
    const float target = wanted_delay && tap->missed < 8 && access(SYNC_READY, R_OK) == 0 ? 1 : 0;
    if (!tap->started) {
        tap->wet = target;
        tap->started = 1;
    }

    float blend = tap->wet;
    unsigned int ring_pos = tap->ring_pos;
    for (unsigned long i = 0; i < frames; ++i) {
        const float left = tap->port[LEFT_IN][i];
        const float right = tap->port[RIGHT_IN][i];
        float delayed_left = left;
        float delayed_right = right;
        if (wanted_delay) {
            delayed_left = tap->delay[ring_pos][0];
            delayed_right = tap->delay[ring_pos][1];
            tap->delay[ring_pos][0] = left;
            tap->delay[ring_pos][1] = right;
            if (++ring_pos == wanted_delay)
                ring_pos = 0;
        }
        if (blend < target)
            blend = fminf(target, blend + 1.0f / 960);
        else if (blend > target)
            blend = fmaxf(target, blend - 1.0f / 960);
        tap->port[LEFT_OUT][i] = left + blend * (delayed_left - left);
        tap->port[RIGHT_OUT][i] = right + blend * (delayed_right - right);
    }
    tap->ring_pos = ring_pos;
    tap->wet = blend;
}

static void cleanup(LADSPA_Handle handle) {
    struct tap *tap = handle;
    if (tap->socket >= 0)
        close(tap->socket);
    free(tap);
}

static const LADSPA_PortDescriptor ports[PORT_COUNT] = {
    LADSPA_PORT_AUDIO | LADSPA_PORT_INPUT, LADSPA_PORT_AUDIO | LADSPA_PORT_INPUT,
    LADSPA_PORT_AUDIO | LADSPA_PORT_OUTPUT, LADSPA_PORT_AUDIO | LADSPA_PORT_OUTPUT,
    LADSPA_PORT_CONTROL | LADSPA_PORT_INPUT
};
static const char *const names[PORT_COUNT] = {
    "Left In", "Right In", "Left Out", "Right Out", "Local delay in ms"
};
static const LADSPA_PortRangeHint hints[PORT_COUNT] = {
    {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 0, 0},
    {LADSPA_HINT_BOUNDED_BELOW | LADSPA_HINT_BOUNDED_ABOVE | LADSPA_HINT_DEFAULT_0, 0, MAX_DELAY_MS}
};
static const LADSPA_Descriptor descriptor = {
    .UniqueID = 61106, .Label = "lx06_lg_sync", .Name = "LX06 LG audio mirror",
    .Maker = "Local audio configuration", .Copyright = "None",
    .PortCount = PORT_COUNT, .PortDescriptors = ports, .PortNames = names, .PortRangeHints = hints,
    .instantiate = instantiate, .connect_port = connect_port, .activate = activate,
    .run = run, .cleanup = cleanup
};

__attribute__((visibility("default")))
const LADSPA_Descriptor *ladspa_descriptor(unsigned long index) {
    return index == 0 ? &descriptor : NULL;
}
