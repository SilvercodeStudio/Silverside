/*
 * The HDCD decoder from FFmpeg's libavfilter/af_hdcd.c, for one stereo stream.
 * See hdcd.c for its license, and README.md for what Silverside changed.
 */

#ifndef SILVERSIDE_HDCD_H
#define SILVERSIDE_HDCD_H

#include <stdint.h>

/** What the HDCD codes in the audio so far ask of a decoder: FFmpeg's hdcd_detection_data. */
typedef struct hdcd_summary {
    /** 0: no codes (yet); 1: codes, all of which leave the audio as it is; 2: codes that change it. */
    int detected;
    /** 0: no packets; 1: packets of type A (8-bit code); 2: type B (8-bit code, 8-bit check); 3: both. */
    int packet_type;
    /** Valid packets. */
    int total_packets;
    /** Packets that looked damaged. */
    int errors;
    /** 0: peak extend never on; 1: on in some packets; 2: on in every packet. */
    int peak_extend;
    int uses_transient_filter;
    /** The largest gain adjustment the codes ask for, in dB: 0.0 down to -7.5. */
    float max_gain_adjustment;
    /** Times the code detect timer ran out with no new code; -1 if it never started. */
    int cdt_expirations;
} hdcd_summary;

typedef struct hdcd_decoder hdcd_decoder;

/** A decoder with FFmpeg's default options. NULL if there is no memory. */
hdcd_decoder *hdcd_decoder_new(int sample_rate);
void hdcd_decoder_free(hdcd_decoder *decoder);

/**
 * Decodes `count` stereo frames in place: interleaved 16-bit values (left, right, ...)
 * in, 32-bit values out. Feed the stream in order, in blocks as FFmpeg would (4096 frames).
 */
void hdcd_decoder_process(hdcd_decoder *decoder, int32_t *samples, int count);

/** What the decoder has found so far. */
hdcd_summary hdcd_decoder_summary(const hdcd_decoder *decoder);

#endif
