#!/usr/bin/env python3
"""四视图 -> GLB：上传到 R2，提交 Tripo3D multiview_to_model，轮询并下载。

    python3 tools/assets/tripo_multiview.py \
        --name male_gunner_kit \
        --dir assets/source_art/player_characters/kits_v6/male_gunner \
        --out assets/generated_models/tripo/kits/male_gunner.glb

    # 批量：一行一个 "name<TAB>dir<TAB>out"
    python3 tools/assets/tripo_multiview.py --batch jobs.tsv --concurrency 3

凭据来源：
- Tripo 网关 key      ~/Library/Application Support/43Coding/settings.json 的 aihubApiKey
- R2                  lumen 项目 .env 的 S3_*，用于把本地图片变成 Tripo 能取的公开 URL

Tripo 的 files 顺序固定是 前、左、后、右，不是 UI 展示顺序。同时运行的任务控制在
2-3 个，避免触发并发或额度限制。
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import boto3

SETTINGS = Path.home() / "Library/Application Support/43Coding/settings.json"
LUMEN_ENV = Path("/Users/liangpingbo/Desktop/4399/frontend/lumen/.env")
TRIPO_BASE = "https://aihub.gz4399.com/api/aihub/v1/rawproxy/tripo3d/v2/openapi"

# Tripo multiview 的接口顺序，不是 UI 展示顺序。
VIEW_ORDER = ["front", "left", "back", "right"]


def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for line in path.read_text(errors="ignore").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def api_key() -> str:
    return json.loads(SETTINGS.read_text())["aihubApiKey"]


def post(path: str, payload: dict) -> dict:
    req = urllib.request.Request(
        f"{TRIPO_BASE}{path}",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {api_key()}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def get(path: str) -> dict:
    req = urllib.request.Request(
        f"{TRIPO_BASE}{path}", headers={"Authorization": f"Bearer {api_key()}"}
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def upload_views(name: str, view_dir: Path, env: dict[str, str]) -> list[str]:
    s3 = boto3.client(
        "s3",
        endpoint_url=env["S3_ENDPOINT"],
        aws_access_key_id=env["S3_ACCESS_KEY_ID"],
        aws_secret_access_key=env["S3_SECRET_ACCESS_KEY"],
        region_name="auto",
    )
    urls: list[str] = []
    for view in VIEW_ORDER:
        src = view_dir / f"{view}.png"
        if not src.exists():
            raise SystemExit(f"[{name}] 缺少视图 {src}")
        key = f"zombiewar/v6/{name}/{view}.png"
        s3.upload_file(str(src), env["S3_BUCKET"], key, ExtraArgs={"ContentType": "image/png"})
        urls.append(f'{env["S3_PUBLIC_DOMAIN"]}/{key}')
    return urls


def submit(name: str, urls: list[str]) -> str:
    payload = {
        "type": "multiview_to_model",
        # 四个独立文件对象，不能把四视图拼成一张图提交。
        "files": [{"type": "png", "url": u} for u in urls],
        "model_version": "v3.0-20250812",
        "texture": True,
        "texture_quality": "detailed",
    }
    res = post("/task", payload)
    if res.get("code") != 0:
        raise SystemExit(f"[{name}] 提交失败: {res}")
    return res["data"]["task_id"]


def wait(name: str, task_id: str, timeout_s: int = 1800) -> dict:
    deadline = time.time() + timeout_s
    last = -1
    while time.time() < deadline:
        data = get(f"/task/{task_id}")["data"]
        status, progress = data.get("status"), data.get("progress", 0)
        if progress != last:
            print(f"[{name}] {status} {progress}%", flush=True)
            last = progress
        if status == "success":
            return data
        if status in ("failed", "banned", "cancelled", "unknown"):
            raise SystemExit(f"[{name}] 任务 {status}: {data}")
        time.sleep(10)
    raise SystemExit(f"[{name}] 超时，task_id={task_id}")


def download(name: str, data: dict, out: Path) -> Path:
    output = data.get("output", {})
    url = output.get("pbr_model") or output.get("model") or output.get("base_model")
    if not url:
        raise SystemExit(f"[{name}] 结果里没有模型地址: {output}")
    out.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=600) as r, out.open("wb") as f:
        f.write(r.read())
    return out


def run_one(name: str, view_dir: Path, out: Path, env: dict[str, str]) -> dict:
    urls = upload_views(name, view_dir, env)
    task_id = submit(name, urls)
    print(f"[{name}] task_id={task_id}", flush=True)
    data = wait(name, task_id)
    path = download(name, data, out)
    print(f"[{name}] 完成 -> {path}", flush=True)
    return {"name": name, "task_id": task_id, "glb": str(path), "views": urls}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name")
    ap.add_argument("--dir")
    ap.add_argument("--out")
    ap.add_argument("--batch", help="TSV: name<TAB>view_dir<TAB>out_glb")
    ap.add_argument("--concurrency", type=int, default=3, help="Tripo 同时运行任务数，建议 2-3")
    ap.add_argument("--record", default="docs/assets/player-characters/tripo-tasks.jsonl")
    args = ap.parse_args()

    env = load_env(LUMEN_ENV)
    jobs: list[tuple[str, Path, Path]] = []
    if args.batch:
        for line in Path(args.batch).read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                n, d, o = line.split("\t")
                jobs.append((n, Path(d), Path(o)))
    elif args.name and args.dir and args.out:
        jobs.append((args.name, Path(args.dir), Path(args.out)))
    else:
        ap.error("需要 --name/--dir/--out 或 --batch")

    results, failures = [], []
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = {pool.submit(run_one, n, d, o, env): n for n, d, o in jobs}
        for fut in as_completed(futures):
            name = futures[fut]
            try:
                results.append(fut.result())
            except SystemExit as exc:
                print(f"[{name}] 失败: {exc}", file=sys.stderr, flush=True)
                failures.append(name)

    # task_id 与源图 URL 是溯源要求，失败也要留痕，不重复盲目提交。
    record = Path(args.record)
    record.parent.mkdir(parents=True, exist_ok=True)
    with record.open("a") as f:
        for r in results:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    print(f"\n成功 {len(results)}/{len(jobs)}")
    if failures:
        print(f"失败: {', '.join(failures)}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
