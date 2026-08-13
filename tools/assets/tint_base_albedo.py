#!/usr/bin/env python3
"""把基体底衣改成角色识别色，保留手绘磨损和明暗。

v5 的两套基体底衣是紫黑的，10 个角色共用，所以全员一个颜色。这个工具按色相
选出底衣像素、重映射到目标色，皮肤、头发、靴子、皮件因为色相不同不受影响，
因此不需要重新出图就能派生出 10 个角色的底衣。

用法:
    # 先看选区对不对（白=会被改色）
    python3 tools/assets/tint_base_albedo.py in.png --target '#2F3620' --mask-out mask.png

    # 确认选区后正式输出
    python3 tools/assets/tint_base_albedo.py in.png --target '#2F3620' -o male_gunner_base.png

    # 按 palette-v6.json 一次导出全部 10 个角色
    python3 tools/assets/tint_base_albedo.py --from-palette \\
        --base-image assets/source_art/player_characters/bases/male_base/front_final.png \\
        --base-id male_standard -o out/

紫色底衣的默认色相窗口是 250-330 度。若源图换成中性灰底衣（新基体走这条路），
用 --gray-source 改走亮度选区。
"""

from __future__ import annotations

import argparse
import colorsys
import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
PALETTE = ROOT / "docs/assets/player-characters/palette-v6.json"


def hex_to_rgb01(value: str) -> tuple[float, float, float]:
    value = value.lstrip("#")
    if len(value) != 6:
        raise ValueError(f"期望 6 位十六进制颜色，收到 {value!r}")
    return tuple(int(value[i : i + 2], 16) / 255.0 for i in (0, 2, 4))  # type: ignore[return-value]


def rgb_to_hsv_array(rgb: np.ndarray) -> np.ndarray:
    """向量化 RGB->HSV，rgb 为 float32 [...,3] 且取值 0-1。H 输出 0-360。"""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx = rgb.max(axis=-1)
    mn = rgb.min(axis=-1)
    diff = mx - mn

    hue = np.zeros_like(mx)
    safe = diff > 1e-6
    # 每个分支只在该分支为最大值处取值，避免除零。
    idx = safe & (mx == r)
    hue[idx] = (60 * ((g[idx] - b[idx]) / diff[idx])) % 360
    idx = safe & (mx == g)
    hue[idx] = (60 * ((b[idx] - r[idx]) / diff[idx]) + 120) % 360
    idx = safe & (mx == b)
    hue[idx] = (60 * ((r[idx] - g[idx]) / diff[idx]) + 240) % 360

    sat = np.zeros_like(mx)
    nz = mx > 1e-6
    sat[nz] = diff[nz] / mx[nz]
    return np.stack([hue, sat, mx], axis=-1)


def build_mask(
    hsv: np.ndarray,
    hue_lo: float,
    hue_hi: float,
    sat_min: float,
    value_max: float,
    gray_source: bool,
) -> np.ndarray:
    hue, sat, val = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    if gray_source:
        # 中性灰底衣没有可用色相，改用「低饱和 + 暗」来选。
        return (sat <= sat_min) & (val <= value_max)
    if hue_lo <= hue_hi:
        in_hue = (hue >= hue_lo) & (hue <= hue_hi)
    else:  # 跨过 0 度
        in_hue = (hue >= hue_lo) | (hue <= hue_hi)
    return in_hue & (sat >= sat_min) & (val <= value_max)


def tint(
    image: Image.Image,
    target_hex: str,
    hue_lo: float,
    hue_hi: float,
    sat_min: float,
    value_max: float,
    gray_source: bool,
) -> tuple[Image.Image, Image.Image, float]:
    src = image.convert("RGBA")
    arr = np.asarray(src).astype(np.float32) / 255.0
    rgb, alpha = arr[..., :3], arr[..., 3:]

    hsv = rgb_to_hsv_array(rgb)
    mask = build_mask(hsv, hue_lo, hue_hi, sat_min, value_max, gray_source)
    coverage = float(mask.mean())

    out = rgb.copy()
    if mask.any():
        t_h, t_s, t_v = colorsys.rgb_to_hsv(*hex_to_rgb01(target_hex))
        t_h *= 360.0

        val = hsv[..., 2][mask]
        # 保留原有明暗起伏（磨损、褶皱、投影），只把整体亮度对齐到目标色。
        mean_val = float(val.mean())
        scaled = np.clip(val * (t_v / mean_val) if mean_val > 1e-6 else val, 0.0, 1.0)

        h_arr = np.full(scaled.shape, t_h / 360.0, dtype=np.float32)
        s_arr = np.full(scaled.shape, t_s, dtype=np.float32)
        # 原本越灰的像素（磨白处）保留更少饱和度，磨损才不会被染平。
        s_arr = s_arr * np.clip(hsv[..., 1][mask] / max(sat_min, 1e-3), 0.35, 1.0)

        i = np.floor(h_arr * 6.0)
        f = h_arr * 6.0 - i
        p = scaled * (1.0 - s_arr)
        q = scaled * (1.0 - f * s_arr)
        t = scaled * (1.0 - (1.0 - f) * s_arr)
        i = (i % 6).astype(np.int32)

        r = np.select([i == 0, i == 1, i == 2, i == 3, i == 4], [scaled, q, p, p, t], default=scaled)
        g = np.select([i == 0, i == 1, i == 2, i == 3, i == 4], [t, scaled, scaled, q, p], default=p)
        b = np.select([i == 0, i == 1, i == 2, i == 3, i == 4], [p, p, t, scaled, scaled], default=q)
        out[mask] = np.stack([r, g, b], axis=-1)

    result = Image.fromarray(
        (np.concatenate([np.clip(out, 0, 1), alpha], axis=-1) * 255).astype(np.uint8), "RGBA"
    )
    mask_img = Image.fromarray((mask * 255).astype(np.uint8), "L")
    return result, mask_img, coverage


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", nargs="?", help="源基体贴图/视图 PNG")
    parser.add_argument("-o", "--out", help="输出 PNG；配合 --from-palette 时是输出目录")
    parser.add_argument("--target", help="目标底衣色，如 '#2F3620'")
    parser.add_argument("--mask-out", help="额外导出选区预览（白=会被改色）")
    parser.add_argument("--from-palette", action="store_true", help="按 palette-v6.json 批量导出该基体下的全部角色")
    parser.add_argument("--base-image", help="--from-palette 用的源图")
    parser.add_argument("--base-id", help="--from-palette 用的基体 id，如 male_standard")
    parser.add_argument("--hue-lo", type=float, default=250.0, help="底衣色相下界，默认 250（紫）")
    parser.add_argument("--hue-hi", type=float, default=330.0, help="底衣色相上界，默认 330（紫）")
    parser.add_argument("--sat-min", type=float, default=0.10, help="最低饱和度，默认 0.10")
    parser.add_argument("--value-max", type=float, default=0.62, help="最高明度，默认 0.62，挡掉米白皮件")
    parser.add_argument("--gray-source", action="store_true", help="源图底衣是中性灰时改用亮度选区")
    args = parser.parse_args()

    common = dict(
        hue_lo=args.hue_lo,
        hue_hi=args.hue_hi,
        sat_min=args.sat_min,
        value_max=args.value_max,
        gray_source=args.gray_source,
    )

    if args.from_palette:
        if not (args.base_image and args.base_id and args.out):
            parser.error("--from-palette 需要 --base-image、--base-id 和 -o 输出目录")
        data = json.loads(PALETTE.read_text(encoding="utf-8"))
        members = [c for c in data["characters"] if c["base"] == args.base_id]
        if not members:
            parser.error(f"palette-v6.json 里没有 base 为 {args.base_id!r} 的角色")
        src = Image.open(args.base_image)
        out_dir = Path(args.out)
        out_dir.mkdir(parents=True, exist_ok=True)
        stem = Path(args.base_image).stem
        for character in members:
            result, _, coverage = tint(src, character["undersuit_tint"], **common)
            path = out_dir / f"{character['id']}_{stem}.png"
            result.save(path)
            print(f"{character['id']:20s} {character['undersuit_tint']}  选区 {coverage:6.1%}  -> {path}")
        return

    if not (args.image and args.target):
        parser.error("需要 image 和 --target（或改用 --from-palette）")

    src = Image.open(args.image)
    result, mask_img, coverage = tint(src, args.target, **common)
    print(f"选区覆盖 {coverage:.1%} 的画布像素")
    if args.mask_out:
        mask_img.save(args.mask_out)
        print(f"选区预览 -> {args.mask_out}")
    if args.out:
        result.save(args.out)
        print(f"输出 -> {args.out}")
    elif not args.mask_out:
        parser.error("需要 -o 或 --mask-out 之一")


if __name__ == "__main__":
    main()
