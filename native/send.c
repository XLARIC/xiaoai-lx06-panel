#define _GNU_SOURCE
#include "stream.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* Public ALSA PCM ABI used by the firmware's 32-bit libasound. */
typedef struct _snd_pcm snd_pcm_t;
typedef unsigned long snd_pcm_uframes_t;
typedef long snd_pcm_sframes_t;
extern int snd_pcm_open(snd_pcm_t **, const char *, int, int);
extern int snd_pcm_set_params(snd_pcm_t *, int, int, unsigned int, unsigned int, int, unsigned int);
extern int snd_pcm_get_params(snd_pcm_t *, snd_pcm_uframes_t *, snd_pcm_uframes_t *);
extern int snd_pcm_start(snd_pcm_t *);
extern int snd_pcm_state(snd_pcm_t *);
extern snd_pcm_sframes_t snd_pcm_avail_update(snd_pcm_t *);
extern snd_pcm_sframes_t snd_pcm_writei(snd_pcm_t *, const void *, snd_pcm_uframes_t);
extern int snd_pcm_recover(snd_pcm_t *, int, int);
extern int snd_pcm_close(snd_pcm_t *);
extern const char *snd_strerror(int);

enum { PCM_PLAYBACK = 0, PCM_NONBLOCK = 1, PCM_S16_LE = 2, PCM_INTERLEAVED = 3, PCM_RUNNING = 3 };
enum { CHUNK = 480, TARGET_QUEUE = 1440, CAPACITY = 12288, KEEP_AFTER_OVERRUN = 4320 };

struct receiver {
    struct stereo_frame fifo[CAPACITY];
    unsigned int head;
    unsigned int used;
    uint32_t active_stream;
    uint32_t next_offset;
    uint64_t received_at;
    unsigned long received, played, resets, overruns;
    int peak;
    double phase, average_depth;
    int streaming;
};

static volatile sig_atomic_t running = 1;

static void stop(int signal_number) {
    (void)signal_number;
    running = 0;
}

static uint64_t milliseconds(void) {
    struct timespec now = {0};
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000 + (unsigned long)now.tv_nsec / 1000000;
}

static void consume(struct receiver *state, unsigned int count) {
    state->head = (state->head + count) % CAPACITY;
    state->used -= count;
}

static void reset_queue(struct receiver *state) {
    state->head = 0;
    state->used = 0;
    state->phase = 0;
    state->average_depth = TARGET_QUEUE;
    state->streaming = 0;
}

static void enqueue(struct receiver *state, const struct pcm_packet *packet) {
    if (state->used + packet->frames > CAPACITY) {
        consume(state, state->used - KEEP_AFTER_OVERRUN);
        ++state->overruns;
    }
    const unsigned int tail = (state->head + state->used) % CAPACITY;
    for (unsigned int i = 0; i < packet->frames; ++i) {
        const struct stereo_frame frame = packet->samples[i];
        state->fifo[(tail + i) % CAPACITY] = frame;
        int left = frame.left < 0 ? -(int)frame.left : frame.left;
        int right = frame.right < 0 ? -(int)frame.right : frame.right;
        if (left > state->peak) state->peak = left;
        if (right > state->peak) state->peak = right;
    }
    state->used += packet->frames;
    state->received += packet->frames;
}

static void receive(int fd, struct receiver *state, uint64_t now) {
    for (int i = 0; i < 40; ++i) {
        struct pcm_packet packet;
        const ssize_t size = recv(fd, &packet, sizeof(packet), MSG_DONTWAIT);
        if (size < 0)
            break;
        if (size < (ssize_t)offsetof(struct pcm_packet, samples) || packet.magic != PCM_MAGIC ||
            packet.frames == 0 || packet.frames > MAX_PACKET_FRAMES ||
            (size_t)size != offsetof(struct pcm_packet, samples) + packet.frames * sizeof(struct stereo_frame))
            continue;
        /* Prefer the current stream if a separate prompt briefly opens a PCM. */
        const int fresh = !state->received || now - state->received_at > 160;
        if (packet.stream != state->active_stream && !fresh)
            continue;
        if (fresh || packet.offset != state->next_offset) {
            reset_queue(state);
            ++state->resets;
        }
        state->active_stream = packet.stream;
        state->next_offset = packet.offset + packet.frames;
        state->received_at = now;
        enqueue(state, &packet);
    }
}

static struct stereo_frame next_frame(struct receiver *state, double speed) {
    if (state->used < 2) {
        if (state->used)
            consume(state, 1);
        state->streaming = 0;
        state->phase = 0;
        return (struct stereo_frame){0};
    }
    const struct stereo_frame first = state->fifo[state->head];
    const struct stereo_frame second = state->fifo[(state->head + 1) % CAPACITY];
    const struct stereo_frame output = {
        first.left + (second.left - first.left) * state->phase,
        first.right + (second.right - first.right) * state->phase
    };
    state->phase += speed;
    const unsigned int whole = (unsigned int)state->phase;
    consume(state, whole > state->used ? state->used : whole);
    state->phase -= whole;
    return output;
}

static void fill(struct receiver *state, struct stereo_frame *output) {
    if (!state->streaming && state->used >= TARGET_QUEUE)
        state->streaming = 1;
    state->average_depth += 0.03 * (state->used - state->average_depth);
    double correction = (state->average_depth - (TARGET_QUEUE + CHUNK)) * 0.0000007;
    if (correction > 0.004)
        correction = 0.004;
    if (correction < -0.004)
        correction = -0.004;
    for (unsigned int i = 0; i < CHUNK; ++i) {
        if (state->streaming) {
            output[i] = next_frame(state, 1 + correction);
            ++state->played;
        } else {
            output[i] = (struct stereo_frame){0};
        }
    }
}

static int open_socket(void) {
    const int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -1;
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    strcpy(addr.sun_path, SYNC_SOCKET);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    chmod(SYNC_SOCKET, 0600);
    return fd;
}

static int play(int fd, const char *device) {
    snd_pcm_t *pcm = NULL;
    int status = snd_pcm_open(&pcm, device, PCM_PLAYBACK, PCM_NONBLOCK);
    if (status < 0) {
        fprintf(stderr, "LG PCM open: %s\n", snd_strerror(status));
        return 1;
    }
    status = snd_pcm_set_params(pcm, PCM_S16_LE, PCM_INTERLEAVED, 2, SAMPLE_RATE, 1, 120000);
    if (status < 0)
        goto fail;
    snd_pcm_uframes_t buffer, period;
    status = snd_pcm_get_params(pcm, &buffer, &period);
    if (status < 0)
        goto fail;
    if (buffer < CHUNK || period == 0) {
        status = -EINVAL;
        goto fail;
    }
    const snd_pcm_uframes_t goal = period * 3 < buffer ? period * 3 : buffer;
    struct receiver receiver = {0};
    struct pollfd pollfd = {.fd = fd, .events = POLLIN};
    struct stereo_frame pending[CHUNK];
    unsigned int pending_pos = CHUNK;
    int ready = 0;
    uint64_t last_status = 0;
    while (running) {
        const uint64_t now = milliseconds();
        receive(fd, &receiver, now);
        for (unsigned int iteration = 0; iteration < 12; ++iteration) {
            const snd_pcm_sframes_t available = snd_pcm_avail_update(pcm);
            if (available < 0) {
                if (available == -EAGAIN)
                    break;
                status = snd_pcm_recover(pcm, (int)available, 1);
                if (status < 0)
                    goto fail;
                unlink(SYNC_READY);
                ready = 0;
                break;
            }
            const snd_pcm_uframes_t queued = available > (long)buffer ? 0 : buffer - (unsigned long)available;
            if ((unsigned long)available < CHUNK || queued + CHUNK > goal)
                break;
            if (pending_pos == CHUNK) {
                fill(&receiver, pending);
                pending_pos = 0;
            }
            const snd_pcm_sframes_t written = snd_pcm_writei(pcm, pending + pending_pos, CHUNK - pending_pos);
            if (written == -EAGAIN || written == 0)
                break;
            if (written < 0) {
                status = snd_pcm_recover(pcm, (int)written, 1);
                if (status < 0)
                    goto fail;
                unlink(SYNC_READY);
                ready = 0;
                break;
            }
            pending_pos += (unsigned int)written;
            if (!ready && queued + written >= period) {
                if (snd_pcm_state(pcm) != PCM_RUNNING && (status = snd_pcm_start(pcm)) < 0)
                    goto fail;
                const int flag = open(SYNC_READY, O_CREAT | O_WRONLY | O_CLOEXEC, 0600);
                if (flag < 0) {
                    status = -errno;
                    goto fail;
                }
                close(flag);
                ready = 1;
                printf("LG_AUDIO_READY buffer_frames=%lu period_frames=%lu\n", buffer, period);
            }
        }
        if (receiver.received && now - last_status >= 5000) {
            printf("LG_AUDIO received=%lu played=%lu queued=%u resets=%lu overruns=%lu peak=%d\n",
                   receiver.received, receiver.played, receiver.used, receiver.resets, receiver.overruns, receiver.peak);
            receiver.peak = 0;
            last_status = now;
        }
        poll(&pollfd, 1, 5);
    }
    snd_pcm_close(pcm);
    return 0;

fail:
    fprintf(stderr, "LG PCM: %s\n", snd_strerror(status));
    snd_pcm_close(pcm);
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 2)
        return 2;
    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGINT, stop);
    signal(SIGTERM, stop);
    const int fd = open_socket();
    if (fd < 0) {
        perror("LG audio socket");
        return 1;
    }
    unlink(SYNC_READY);
    const int status = play(fd, argv[1]);
    unlink(SYNC_READY);
    unlink(SYNC_SOCKET);
    close(fd);
    return status;
}
