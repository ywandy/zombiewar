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
    import boto3  # 惰性导入：--resume-task 只下载，不该因为缺 boto3 而失败

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


def submit(name: str, urls: list[str], smart_low_poly: bool = True, attempts: int = 8) -> str:
    payload = {
        "type": "multiview_to_model",
        # 四个独立文件对象，不能把四视图拼成一张图提交。
        "files": [{"type": "png", "url": u} for u in urls],
        "model_version": "v3.0-20250812",
        "texture": True,
        "texture_quality": "detailed",
    }
    if smart_low_poly:
        # 智能网格：生成时就规划拓扑，直接给出约 1.5 万面的可用低模。
        # 默认的 geometry_quality=standard 会产出 74 万面，必须靠 Blender 的 Collapse
        # Decimate 硬压 96%——那不看拓扑，只按误差合并边，护膝会糊成圆片、弹链会连成
        # 一条模糊带子，而且是形变撕裂问题的根源（碎壳、UV 接缝、权重不连续都被它加剧）。
        #
        # 注意：smart_low_poly 与 face_limit 互斥，同时传会失败并返回 error_code 1004。
        payload["smart_low_poly"] = True
    # 全量并发时会撞并发/额度上限。撞上就退避重排队，不能让任务直接失败丢掉。
    delay = 15
    for attempt in range(1, attempts + 1):
        try:
            res = post("/task", payload)
        except Exception as exc:  # 网关 429/5xx 也走同一条退避路径
            if attempt == attempts:
                raise SystemExit(f"[{name}] 提交失败（{attempts} 次）: {exc}")
            print(f"[{name}] 提交异常，{delay}s 后重试 ({attempt}/{attempts}): {exc}", flush=True)
            time.sleep(delay)
            delay = min(delay * 2, 180)
            continue
        if res.get("code") == 0:
            return res["data"]["task_id"]
        msg = str(res)
        throttled = any(k in msg for k in ("concurren", "limit", "quota", "rate", "too many", "busy"))
        if not throttled or attempt == attempts:
            raise SystemExit(f"[{name}] 提交失败: {res}")
        print(f"[{name}] 被限流，{delay}s 后重排队 ({attempt}/{attempts})", flush=True)
        time.sleep(delay)
        delay = min(delay * 2, 180)
    raise SystemExit(f"[{name}] 提交失败：重试用尽")


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
    # 先写 .part 再改名：下载被中断时不会留下一个 0 字节的文件冒充成功产物。
    part = out.with_suffix(out.suffix + ".part")
    # 高并发下 CDN 会重置连接，单次失败不该让整个任务作废。
    for attempt in range(1, 6):
        written = 0
        try:
            with urllib.request.urlopen(url, timeout=900) as r, part.open("wb") as f:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
                    written += len(chunk)
                    if written % (16 << 20) < (1 << 20):
                        print(f"[{name}] 下载 {written / 1048576:.0f} MB", flush=True)
        except Exception as exc:
            print(f"[{name}] 下载中断于 {written / 1048576:.0f} MB，重试 {attempt}/5: {exc}", flush=True)
            part.unlink(missing_ok=True)
            time.sleep(min(10 * attempt, 60))
            continue
        if written == 0:
            part.unlink(missing_ok=True)
            time.sleep(min(10 * attempt, 60))
            continue
        part.replace(out)
        return out
    raise SystemExit(f"[{name}] 下载失败：重试用尽")


def run_one(name: str, view_dir: Path, out: Path, env: dict[str, str],
            smart_low_poly: bool = True) -> dict:
    urls = upload_views(name, view_dir, env)
    task_id = submit(name, urls, smart_low_poly)
    print(f"[{name}] task_id={task_id}", flush=True)
    data = wait(name, task_id)
    path = download(name, data, out)
    print(f"[{name}] 完成 -> {path}", flush=True)
    return {"name": name, "task_id": task_id, "glb": str(path), "views": urls,
            "smart_low_poly": smart_low_poly}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name")
    ap.add_argument("--dir")
    ap.add_argument("--out")
    ap.add_argument("--batch", help="TSV: name<TAB>view_dir<TAB>out_glb")
    ap.add_argument("--resume-task", help="已成功的 task_id，只重新下载，不重跑生成")
    ap.add_argument("--concurrency", type=int, default=3, help="Tripo 同时运行任务数，建议 2-3")
    ap.add_argument("--no-smart-low-poly", action="store_true",
                    help="关闭智能网格，退回 74 万面的高精度模型（需自行减面）")
    ap.add_argument("--record", default="docs/assets/player-characters/tripo-tasks.jsonl")
    args = ap.parse_args()

    if args.resume_task:
        if not args.out:
            ap.error("--resume-task 需要 --out")
        name = args.name or args.resume_task[:8]
        data = get(f"/task/{args.resume_task}")["data"]
        if data.get("status") != "success":
            raise SystemExit(f"[{name}] 任务状态是 {data.get('status')}，无法下载")
        print(f"[{name}] 完成 -> {download(name, data, Path(args.out))}")
        return

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
        futures = {pool.submit(run_one, n, d, o, env, not args.no_smart_low_poly): n for n, d, o in jobs}
        for fut in as_completed(futures):
            name = futures[fut]
            try:
                results.append(fut.result())
            except (SystemExit, Exception) as exc:
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
