# HDCD decoder

The HDCD decoder from FFmpeg, `libavfilter/af_hdcd.c`, as of 2026-10-23 (FFmpeg 9.0.2's
filter is the same code). It is under its own BSD license, in `LICENSE` and at the top of
`hdcd.c`, not Silverside's MIT License.

What Silverside changed, all in `hdcd.c`:

- The FFmpeg includes are replaced by the C library's, and by stand-ins for `FFMIN`,
  `FFMAX`, `av_assert0`, and `av_log` (the decoder's log lines are left out), and a pragma that turns off a
  warning FFmpeg's build does not turn on.
- The two FFmpeg fields of `HDCDContext` (the class, and the filter context for the log)
  are left out.
- The filter (its options, `filter_frame`, `query_formats`, `init`, `uninit`, and
  `config_input`) is replaced by the functions in `include/hdcd.h`: a decoder for one
  stereo stream at 16 bits, with the filter's default options.

The decoding itself (`hdcd_integrate`, `hdcd_scan`, `hdcd_envelope`, `hdcd_process_stereo`,
the detection, and the tables) is FFmpeg's, unchanged, so that it gives the same results
as `ffmpeg -af hdcd`. Keep it that way: a fix belongs upstream first.

`SilversideKit/Sources/SilversideKit/HDCD.swift` uses it.
