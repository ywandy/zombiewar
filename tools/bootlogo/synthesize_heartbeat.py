#!/usr/bin/env python3
"""Synthesize a cinematic two-beat heartbeat for the boot splash.

A heartbeat is a "lub-dub": a slightly louder low thump (S1) followed ~0.3s
later by a softer, shorter one (S2). We render two such pairs to sit under the
~3.5s logo crossfade, then fade out. Output is a 16-bit mono WAV; the caller
converts to mp3/ogg for shipping.

Each thump = a pitch-dropping sine (60 -> 40 Hz) with a fast attack / exp decay,
plus a filtered noise "thud" transient for body. Pure numpy + stdlib wave.

Usage:
  python3 tools/bootlogo/synthesize_heartbeat.py assets/sfx/ui/heartbeat.wav
"""
from __future__ import annotations

import math
import sys

import numpy as np

SR = 44100


def thump(dur: float, f_start: float, f_end: float, gain: float) -> np.ndarray:
    """One low thump: downward pitch sweep sine with exponential decay + thud."""
    n = int(SR * dur)
    t = np.arange(n) / SR
    # Instantaneous frequency sweeps f_start -> f_end exponentially.
    phase = 2.0 * math.pi * (f_end * t + (f_start - f_end) * (1.0 - np.exp(-t / 0.06)) * 0.06)
    body = np.sin(phase)
    # Fast attack, exponential release.
    env = np.minimum(t / 0.008, 1.0) * np.exp(-t / 0.11)
    # A short noise transient at the very start gives the "thud" its knock.
    noise = np.random.default_rng(7).standard_normal(n)
    noise_env = np.exp(-t / 0.02)
    thud = noise * noise_env * 0.35
    return (body * env + thud) * gain


def place(track: np.ndarray, at_sec: float, sig: np.ndarray) -> None:
    i = int(at_sec * SR)
    j = min(i + sig.size, track.size)
    track[i:j] += sig[: j - i]


def main() -> int:
    out = sys.argv[1] if len(sys.argv) > 1 else "assets/sfx/ui/heartbeat.wav"

    total = 3.2  # seconds; matches the boot crossfade with a short tail.
    track = np.zeros(int(SR * total), dtype=np.float64)

    # Two heartbeats. Each: lub (louder) then dub (softer, ~0.32s later).
    for beat_start in (0.15, 1.45):
        place(track, beat_start, thump(0.22, 62.0, 40.0, 0.9))   # lub
        place(track, beat_start + 0.32, thump(0.18, 56.0, 38.0, 0.6))  # dub

    # Gentle overall fade-out so the last beat doesn't click into the menu.
    fade = int(SR * 0.5)
    track[-fade:] *= np.linspace(1.0, 0.0, fade)

    # Soft-clip / normalize to -1 dBFS headroom.
    peak = np.max(np.abs(track)) or 1.0
    track = track / peak * 0.89

    pcm = (track * 32767.0).astype(np.int16)
    import wave

    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"wrote {out} ({total}s, {SR} Hz mono 16-bit)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
