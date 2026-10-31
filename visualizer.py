#!/usr/bin/env python3
"""Print one line of spectrum levels (0-100) per frame from the default sink."""
import signal
import subprocess
import sys

import numpy as np

RATE = 44100
FPS = 30
BARS = 40
WINDOW = 2048
LOW_HZ = 40
HIGH_HZ = 14000
HOP_BYTES = RATE // FPS * 2


def band_edges():
    freqs = np.fft.rfftfreq(WINDOW, 1 / RATE)
    edges = np.geomspace(LOW_HZ, HIGH_HZ, BARS + 1)
    starts = np.searchsorted(freqs, edges[:-1])
    stops = np.maximum(np.searchsorted(freqs, edges[1:]), starts + 1)
    return starts, stops


def main():
    recorder = subprocess.Popen(
        ["pw-record", "--raw", "--format", "s16", "--rate", str(RATE), "--channels", "1",
         "-P", "{ stream.capture.sink=true node.dont-reconnect=false }", "-"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    starts, stops = band_edges()
    hann = np.hanning(WINDOW)
    samples = np.zeros(WINDOW)
    levels = np.zeros(BARS)
    peak = 0.05

    try:
        while True:
            chunk = recorder.stdout.read(HOP_BYTES)
            if len(chunk) < HOP_BYTES:
                return
            new = np.frombuffer(chunk, dtype="<i2") / 32768
            samples = np.concatenate((samples[len(new):], new))

            spectrum = np.abs(np.fft.rfft(samples * hann))
            bands = np.array([spectrum[a:b].max() for a, b in zip(starts, stops)])
            # Treble carries far less energy, so tilt it up to keep the bars even.
            bands = np.sqrt(bands * np.linspace(1, 6, BARS))

            peak = max(peak * 0.995, bands.max(), 0.05)
            target = bands / peak
            levels = np.where(target > levels, target, levels * 0.82 + target * 0.18)

            print(" ".join(str(int(v * 100)) for v in levels), flush=True)
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    finally:
        recorder.terminate()


if __name__ == "__main__":
    main()
