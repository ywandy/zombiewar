#!/usr/bin/env python3
"""Synthesize a low sub-bass drone to sit under the boot heartbeat.

A menacing pad: a deep sine (~38 Hz) doubled an octave up with slow detune, a
gentle amplitude LFO so it "breathes", a touch of soft saturation for grit, and
a slow swell-in / swell-out envelope. Pure numpy + stdlib wave.

Usage:
  python3 tools/bootlogo/synthesize_drone.py assets/sfx/ui/drone.wav
"""
from __future__ import annotations

import math
import sys

import numpy as np

SR = 44100
DUR = 4.2  # a touch longer than the crossfade so it can ring under the menu cut


def main() -> int:
    out = sys.argv[1] if len(sys.argv) > 1 else "assets/sfx/ui/drone.wav"
    t = np.arange(int(SR * DUR)) / SR

    # Sub root + a slightly detuned octave for thickness.
    sub = np.sin(2.0 * math.pi * 38.0 * t)
    oct_up = np.sin(2.0 * math.pi * 76.5 * t) * 0.35
    fifth = np.sin(2.0 * math.pi * 57.0 * t) * 0.18  # dissonant-ish rub

    sig = sub + oct_up + fifth

    # Slow breathing LFO (~0.5 Hz) so it surges instead of sitting flat.
    lfo = 0.75 + 0.25 * np.sin(2.0 * math.pi * 0.5 * t)
    sig *= lfo

    # Soft saturation for grit without harsh clipping.
    sig = np.tanh(sig * 1.6)

    # Swell in over 0.6s, swell out over the last 1.2s.
    env = np.ones_like(sig)
    attack = int(SR * 0.6)
    env[:attack] = np.linspace(0.0, 1.0, attack)
    release = int(SR * 1.2)
    env[-release:] = np.linspace(1.0, 0.0, release)
    sig *= env

    peak = np.max(np.abs(sig)) or 1.0
    sig = sig / peak * 0.7  # leave room under the heartbeat

    pcm = (sig * 32767.0).astype(np.int16)
    import wave

    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"wrote {out} ({DUR}s, {SR} Hz mono 16-bit)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
