#!/usr/bin/env python3
"""Generate boot-splash logo frames via the codex CLI built-in image_gen tool.

The codex CLI (see ~/.codex/skills/.system/imagegen) can produce raster images
without an OPENAI_API_KEY by calling its built-in `image_gen` tool inside an
agent turn. This script drives `codex exec` once per frame, collects the PNG it
drops under ~/.codex/generated_images/, removes the chroma-key background, and
writes Godot-ready frames into the project's assets/ui/boot/ folder.

Frames produced (DOGWALK-style logo crossfade):
  boot_logo_main.png     clean emblem (hold frame)
  boot_logo_glitch.png   glitch / signal-interference variant (flicker)
  boot_logo_pulse.png    blood-red energy pulse variant (flicker)

Reusable: pass --prompt to generate any sprite/cutout, not just the boot logo.

Usage:
  python3 tools/bootlogo/generate_boot_logos.py                # all 3 frames
  python3 tools/bootlogo/generate_boot_logos.py --only main
  python3 tools/bootlogo/generate_boot_logos.py --force        # regenerate
  python3 tools/bootlogo/generate_boot_logos.py --prompt "..." --out assets/ui/foo.png
"""
from __future__ import annotations

import argparse
import glob
import os
import shutil
import subprocess
import sys
import time

CODEX_HOME = os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex"))
GEN_DIR = os.path.join(CODEX_HOME, "generated_images")
CHROMA_HELPER = os.path.join(
    CODEX_HOME, "skills", ".system", "imagegen", "scripts", "remove_chroma_key.py"
)

# Project-root relative destination for the boot frames.
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BOOT_DIR = os.path.join(REPO_ROOT, "assets", "ui", "boot")

# Shared style block so all three frames read as one emblem.
STYLE = (
    "Gritty zombie-survival video game logo emblem: a weathered human skull seen "
    "dead-on, with a bold military crosshair ring centred over it. Flat vector-game "
    "silhouette style, heavy clean shapes, slightly distressed edges. Palette: dark "
    "military green and blood red with bone-white skull. The emblem must be a single "
    "centred badge, fully separated from the background with crisp edges and generous "
    "padding. No text, no letters, no watermark, no extra objects."
)

# A flat chroma-key backdrop so we can cut the emblem out to alpha locally.
KEY = (
    "Place the emblem on a perfectly flat solid #00ff00 chroma-key background: one "
    "uniform color, no shadows, no gradients, no texture, no reflections, no floor "
    "plane, no lighting variation. Do not use #00ff00 anywhere in the emblem itself. "
    "No cast shadow, no contact shadow, no reflection."
)

FRAMES = {
    "main": f"{STYLE}\n{KEY}",
    "glitch": (
        f"{STYLE} Apply a subtle analog glitch / signal-interference treatment to the "
        f"emblem only: a few horizontal RGB-split scanline tears and slight chromatic "
        f"offset, keeping the skull and crosshair clearly recognisable.\n{KEY}"
    ),
    "pulse": (
        f"{STYLE} Add a blood-red energy glow pulsing from inside the skull eyes and "
        f"around the crosshair ring, as if the emblem is charging up. Keep the emblem "
        f"shape identical.\n{KEY}"
    ),
}

EXEC_TIMEOUT = 240  # seconds per frame
SETTLE_SEC = 2.0


def log(msg: str) -> None:
    print(f"[bootlogo] {msg}", flush=True)


def snapshot_pngs() -> set[str]:
    return set(glob.glob(os.path.join(GEN_DIR, "**", "*.png"), recursive=True))


def newest_new_png(before: set[str]) -> str | None:
    now = set(glob.glob(os.path.join(GEN_DIR, "**", "*.png"), recursive=True))
    fresh = [p for p in (now - before) if os.path.getsize(p) > 0]
    if not fresh:
        return None
    return max(fresh, key=os.path.getmtime)


def run_codex(prompt: str) -> str | None:
    """Fire one codex exec turn that must call image_gen; return the new PNG path."""
    before = snapshot_pngs()
    # Keep the instruction short: long prompts plus the stream's reconnect backoff
    # can push a single frame past the exec timeout. The detailed brief carries the
    # visual spec; this wrapper just forces an actual image_gen call.
    instruction = (
        "Call your built-in image_gen tool right now to generate exactly ONE image "
        "(do not just describe it, actually call the tool and save the image). Brief:\n\n"
        f"{prompt}"
    )
    cmd = [
        "codex", "exec",
        "--skip-git-repo-check",
        "--dangerously-bypass-approvals-and-sandbox",
        instruction,
    ]
    log("launching codex exec (built-in image_gen)...")
    try:
        proc = subprocess.run(
            cmd,
            cwd=REPO_ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
            timeout=EXEC_TIMEOUT,
        )
        log(f"codex exited rc={proc.returncode}")
    except subprocess.TimeoutExpired:
        log(f"codex hit {EXEC_TIMEOUT}s timeout; will still check for a dropped image")

    # The image can land a beat after the process returns; poll briefly for it.
    png = None
    for _ in range(6):
        png = newest_new_png(before)
        if png:
            break
        time.sleep(SETTLE_SEC)
    if png:
        log(f"captured generated image: {png}")
    else:
        log("WARNING: no new image appeared under generated_images/")
    return png


def cut_to_alpha(src_png: str, dst_png: str) -> bool:
    """Remove the chroma-key background so the emblem has a real alpha channel."""
    os.makedirs(os.path.dirname(dst_png), exist_ok=True)
    if not os.path.exists(CHROMA_HELPER):
        log(f"chroma helper missing at {CHROMA_HELPER}; copying raw PNG instead")
        shutil.copyfile(src_png, dst_png)
        return True
    cmd = [
        sys.executable, CHROMA_HELPER,
        "--input", src_png,
        "--out", dst_png,
        "--auto-key", "border",
        "--soft-matte",
        "--transparent-threshold", "12",
        "--opaque-threshold", "220",
        "--despill",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0 or not os.path.exists(dst_png):
        log(f"chroma removal failed ({proc.returncode}); copying raw PNG. {proc.stderr[-300:]}")
        shutil.copyfile(src_png, dst_png)
        return False
    return True


def generate_frame(name: str, prompt: str, out_png: str, force: bool) -> bool:
    if os.path.exists(out_png) and not force:
        log(f"skip {name}: {out_png} already exists (use --force to regenerate)")
        return True
    png = run_codex(prompt)
    if not png:
        log(f"FAILED frame {name}: codex produced no image")
        return False
    ok = cut_to_alpha(png, out_png)
    log(f"frame {name} -> {out_png} ({'alpha' if ok else 'raw'})")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", choices=sorted(FRAMES), help="generate a single named frame")
    ap.add_argument("--force", action="store_true", help="overwrite existing frames")
    ap.add_argument("--prompt", help="custom one-off prompt (bypasses the frame set)")
    ap.add_argument("--out", help="output path for --prompt mode (repo-relative or absolute)")
    args = ap.parse_args()

    if shutil.which("codex") is None:
        log("ERROR: codex CLI not found on PATH")
        return 1

    # One-off custom prompt mode (this is what makes the script reusable).
    if args.prompt:
        if not args.out:
            log("ERROR: --prompt requires --out")
            return 1
        out = args.out if os.path.isabs(args.out) else os.path.join(REPO_ROOT, args.out)
        png = run_codex(args.prompt)
        if not png:
            return 1
        cut_to_alpha(png, out)
        log(f"done -> {out}")
        return 0

    names = [args.only] if args.only else list(FRAMES)
    os.makedirs(BOOT_DIR, exist_ok=True)
    ok = True
    for name in names:
        out = os.path.join(BOOT_DIR, f"boot_logo_{name}.png")
        ok = generate_frame(name, FRAMES[name], out, args.force) and ok

    if ok:
        log("all frames ready. Reopen the Godot editor (or let it reimport) so the")
        log("PNGs under res://assets/ui/boot/ get .import entries before running Boot.")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
