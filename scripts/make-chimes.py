#!/usr/bin/env python3
"""The Mac app's notification chimes, synthesized: ClaunttyMac/Sounds/*.wav.

    python3 scripts/make-chimes.py           # write both
    python3 scripts/make-chimes.py --play    # write both, then play them (afplay)

Edit the notes below and run it again. Each sound is a few soft bell strikes: a sine
with a little of a bell's inharmonic partials, a quick attack and an exponential decay.
Standard library only.
"""

import math
import os
import struct
import subprocess
import sys
import wave

RATE = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ClaunttyMac", "Sounds")

# (start in seconds, frequency in Hz, loudness 0-1)
A5, E6, A6 = 880.0, 1318.5, 1760.0
SOUNDS = {
    # An agent finished: a rising fifth, resolved
    "agent-done": {
        "notes": [(0.0, A5, 0.8), (0.09, E6, 0.7)],
        "decay": 0.16,
        "brightness": 0.18,
    },
    # An agent needs you: the same bell, down and back up, a little brighter
    "agent-needs-you": {
        "notes": [(0.0, E6, 0.75), (0.08, A5, 0.65), (0.16, E6, 0.75)],
        "decay": 0.14,
        "brightness": 0.28,
    },
}

# A bell's partials (ratio to the note, relative level): mostly the fundamental
PARTIALS = [(1.0, 1.0), (2.0, 0.35), (2.76, 0.5), (5.4, 0.25)]


def strike(t, freq, loud, decay, brightness):
    if t < 0:
        return 0.0
    attack = min(1.0, t / 0.004)
    value = 0.0
    for ratio, level in PARTIALS:
        # Higher partials fade faster; brightness sets how much of them there is
        weight = level if ratio == 1.0 else level * brightness / 0.2
        value += weight * math.exp(-t / (decay / ratio ** 0.7)) * math.sin(2 * math.pi * freq * ratio * t)
    return loud * attack * value


def render(spec):
    length = max(start for start, _, _ in spec["notes"]) + spec["decay"] * 3.5
    samples = []
    for n in range(int(length * RATE)):
        t = n / RATE
        samples.append(sum(strike(t - start, freq, loud, spec["decay"], spec["brightness"])
                           for start, freq, loud in spec["notes"]))
    # Peak at -6 dBFS, and a short fade so it ends at silence
    peak = max(abs(s) for s in samples) or 1.0
    gain = 0.5 / peak
    fade = int(0.05 * RATE)
    for k in range(fade):
        samples[-1 - k] *= k / fade
    return [int(max(-1.0, min(1.0, s * gain)) * 32767) for s in samples]


def main():
    os.makedirs(OUT, exist_ok=True)
    paths = []
    for name, spec in SOUNDS.items():
        path = os.path.normpath(os.path.join(OUT, name + ".wav"))
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(b"".join(struct.pack("<h", s) for s in render(spec)))
        print(path)
        paths.append(path)
    if "--play" in sys.argv:
        for path in paths:
            subprocess.run(["afplay", path])


if __name__ == "__main__":
    main()
