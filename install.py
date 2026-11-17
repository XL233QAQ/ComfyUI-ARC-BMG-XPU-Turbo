#!/usr/bin/env python3
"""ARC BMG XPU Turbo - installer.

Installs the Intel Arc Battlemage acceleration stack for ComfyUI.

Design notes
------------
This script **downloads** the three native wheels from their upstream release
page at run time. It does **not** bundle them. This keeps this repository free
of GPL-3.0 binaries (`comfy_aimdo_xpu_runtime` inherits GPL-3.0 from
`comfy-aimdo`), so the MIT license above applies cleanly.

Usage
-----
    python install.py                  # full install
    python install.py --dry-run        # show the plan, change nothing
    python install.py --skip-torch     # only install the omni wheels
    python install.py --no-download    # use wheels already in ./wheels

Requires: Windows x64, Python 3.13, ComfyUI 0.45.x
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

RELEASE_TAG = "v0.2.0"
REPO_SLUG = "wildersa/ComfyUI-Intel-Arc-XPU"
RELEASE_BASE = f"https://github.com/{REPO_SLUG}/releases/download/{RELEASE_TAG}"

TARGET_TORCH = "2.13.0+xpu"
TARGET_PY = (3, 13)

# (display name, filename, sha256, size in bytes or None)
WHEELS = [
    (
        "omni_xpu_kernel",
        "omni_xpu_kernel-0.2.0b3+torch213.bmg-cp313-cp313-win_amd64.whl",
        "a5f3d152bce545c517a2e8f1db958c3c14d67238e7467cfa89bbbb859cb9fd25",
        27_913_749,
    ),
    (
        "comfy_kitchen_xpu_runtime",
        "comfy_kitchen_xpu_runtime-0.2.41-py3-none-any.whl",
        "638756e43526542b625d5a81717bc0721f503e53240416479b42922cde52c605",
        205_272,
    ),
    (
        "comfy_aimdo_xpu_runtime",
        "comfy_aimdo_xpu_runtime-0.6.0-cp39-abi3-win_amd64.whl",
        "6f962d5bdc1f6be61e9ee1d4654b846ff3edea31e4c4fc4640ded6a405756981",
        145_228,
    ),
]

# Mirror used when github.com is unreachable (common in mainland China)
PROXIES = [
    "",
    "https://gh-proxy.com/",
    "https://ghfast.top/",
]

DOWNLOAD_CHUNKS = 16  # 16 ranges in parallel: 26.6 MB in ~95s instead of ~73 min

LAUNCH_FLAGS_ADD = ["--enable-dynamic-vram", "--reserve-vram", "4"]
LAUNCH_FLAG_KEEP = "--enable-manager"

ENV_VARS = {"OMNI_ATTN_BACKEND": "cute"}

HERE = Path(__file__).resolve().parent
WHEELS_DIR = HERE / "wheels"


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------


def say(msg: str = "") -> None:
    print(f"[ARC-Turbo] {msg}", flush=True)


def fail(msg: str) -> None:
    print(f"[ARC-Turbo] CONFLICT: {msg}", file=sys.stderr, flush=True)
    raise SystemExit(1)


def find_comfy_root() -> Path:
    """Locate the ComfyUI installation directory."""
    # 1) explicit override
    env = os.environ.get("COMFYUI_PATH")
    if env and (Path(env) / "main.py").is_file():
        return Path(env)

    # 2) walk up from this script (works when placed in custom_nodes/)
    for parent in [HERE, *HERE.parents]:
        if (parent / "main.py").is_file() and (parent / "comfy").is_dir():
            return parent

    # 3) Comfy Desktop default locations
    local = Path(os.environ.get("LOCALAPPDATA", ""))
    for pattern in (
        "Comfy-Desktop/ComfyUI-Installs/*/ComfyUI",
        "Programs/@comfyorgcomfyui-electron/resources/ComfyUI",
    ):
        for cand in local.glob(pattern):
            if (cand / "main.py").is_file():
                return cand

    fail(
        "Cannot find the ComfyUI directory. Set COMFYUI_PATH to the folder "
        "that contains main.py, or run this script from inside custom_nodes/."
    )
    raise AssertionError("unreachable")


def comfy_python(comfy_root: Path) -> Path:
    """Return the Python interpreter that runs ComfyUI."""
    venv = comfy_root / ".venv" / "Scripts" / "python.exe"
    if venv.is_file():
        return venv
    return Path(sys.executable)


def find_uv(comfy_root: Path) -> Path | None:
    """uv downloads 20 MB/s where bare pip gets 179 KB/s. Prefer it when present."""
    for cand in (
        comfy_root.parent / "standalone-env" / "uv.exe",
        comfy_root / ".venv" / "Scripts" / "uv.exe",
        Path(shutil.which("uv") or ""),
    ):
        if cand and Path(cand).is_file():
            return Path(cand)
    return None


def torch_version(py: Path) -> str | None:
    code = "import torch;print(torch.__version__)"
    try:
        out = subprocess.run(
            [str(py), "-c", code], capture_output=True, text=True, timeout=180
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip().splitlines()[-1] if out.stdout.strip() else None


def installed_version(py: Path, dist: str) -> str | None:
    code = (
        "import importlib.metadata as m, sys\n"
        f"try: print(m.version({dist!r}))\n"
        "except Exception: sys.exit(1)"
    )
    out = subprocess.run([str(py), "-c", code], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else None


def python_version(py: Path) -> tuple[int, int] | None:
    """Return the (major, minor) of the interpreter at *py*."""
    code = "import sys;print('%d.%d' % sys.version_info[:2])"
    try:
        out = subprocess.run(
            [str(py), "-c", code], capture_output=True, text=True, timeout=60
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if out.returncode != 0 or not out.stdout.strip():
        return None
    try:
        major, minor = out.stdout.strip().splitlines()[-1].split(".")
        return int(major), int(minor)
    except ValueError:
        return None


# --------------------------------------------------------------------------
# Download
# --------------------------------------------------------------------------


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _fetch_range(url: str, start: int, end: int, dest: Path) -> int:
    req = urllib.request.Request(
        url, headers={"Range": f"bytes={start}-{end}", "User-Agent": "arc-turbo"}
    )
    with urllib.request.urlopen(req, timeout=120) as r, dest.open("wb") as f:
        shutil.copyfileobj(r, f)
    return dest.stat().st_size


def download_parallel(url: str, dest: Path, total: int) -> None:
    """Split into N ranges and fetch them concurrently.

    Measured: github release assets throttle a single connection to ~34 KB/s
    (26.6 MB -> 73 min). 16 concurrent ranges reach ~286 KB/s (95 s).
    """
    parts_dir = dest.parent / f".parts_{dest.stem}"
    parts_dir.mkdir(parents=True, exist_ok=True)
    chunk = total // DOWNLOAD_CHUNKS + 1
    ranges = [
        (i * chunk, min(total - 1, (i + 1) * chunk - 1))
        for i in range(DOWNLOAD_CHUNKS)
        if i * chunk < total
    ]

    def worker(idx: int, lo: int, hi: int) -> Path:
        part = parts_dir / f"part{idx:02d}"
        last_err: Exception | None = None
        for attempt in range(60):
            proxy = PROXIES[attempt % len(PROXIES)]
            try:
                _fetch_range(proxy + url, lo, hi, part)
                return part
            except Exception as exc:  # noqa: BLE001 - retry any network error
                last_err = exc
        raise RuntimeError(f"chunk {idx} failed after 60 attempts: {last_err}")

    say(f"downloading {dest.name} ({total/1048576:.1f} MB) in {len(ranges)} ranges ...")
    with ThreadPoolExecutor(max_workers=len(ranges)) as pool:
        futures = [pool.submit(worker, i, lo, hi) for i, (lo, hi) in enumerate(ranges)]
        for fut in as_completed(futures):
            fut.result()

    with dest.open("wb") as out:
        for i in range(len(ranges)):
            with (parts_dir / f"part{i:02d}").open("rb") as f:
                shutil.copyfileobj(f, out)
    shutil.rmtree(parts_dir, ignore_errors=True)


def obtain_wheel(name: str, filename: str, sha: str, size: int | None) -> Path:
    """Return a local wheel path, downloading it only if needed."""
    local = WHEELS_DIR / filename
    if local.is_file():
        if sha256_of(local) == sha:
            say(f"{name}: using local {filename}")
            return local
        say(f"{name}: local copy failed checksum, re-downloading")
        local.unlink()

    WHEELS_DIR.mkdir(parents=True, exist_ok=True)
    url = f"{RELEASE_BASE}/{filename}"

    try:
        if size:
            download_parallel(url, local, size)
        else:
            raise RuntimeError("unknown size")
    except Exception as exc:  # noqa: BLE001 - fall back to a plain download
        say(f"{name}: parallel download failed ({exc}); trying single stream")
        ok = False
        for proxy in PROXIES:
            try:
                urllib.request.urlretrieve(proxy + url, local)
                ok = True
                break
            except Exception:  # noqa: BLE001
                continue
        if not ok:
            fail(
                f"could not download {filename}.\n"
                f"  Download it manually from {url}\n"
                f"  and place it in {WHEELS_DIR}"
            )

    actual = sha256_of(local)
    if actual != sha:
        local.unlink(missing_ok=True)
        fail(
            f"checksum mismatch for {filename}\n"
            f"  expected {sha}\n"
            f"  actual   {actual}"
        )
    say(f"{name}: downloaded and verified")
    return local


# --------------------------------------------------------------------------
# Install
# --------------------------------------------------------------------------


def pip_install(py: Path, uv: Path | None, args: list[str]) -> None:
    if uv:
        cmd = [str(uv), "pip", "install", "--python", str(py), *args]
    else:
        cmd = [str(py), "-m", "pip", "install", *args]
    say("  " + " ".join(cmd))
    res = subprocess.run(cmd)
    if res.returncode != 0:
        fail(f"install command failed with exit code {res.returncode}")


def install_torch_stack(py: Path, uv: Path | None, dry: bool) -> None:
    current = torch_version(py)
    say(f"current torch: {current}")
    if current == TARGET_TORCH:
        say("torch already at target, skipping")
        return
    if dry:
        say(f"would install torch=={TARGET_TORCH} + torchvision==0.28.0+xpu")
        return
    say(f"upgrading torch to {TARGET_TORCH} (this takes 30+ minutes)")
    pip_install(
        py,
        uv,
        [
            f"torch=={TARGET_TORCH}",
            "torchvision==0.28.0+xpu",
            "--index-url",
            "https://download.pytorch.org/whl/xpu",
        ],
    )


def install_omni_wheels(py: Path, uv: Path | None, dry: bool) -> None:
    if dry:
        for name, filename, sha, size in WHEELS:
            local = WHEELS_DIR / filename
            if local.is_file() and sha256_of(local) == sha:
                say(f"{name}: would reuse local {filename}")
            else:
                say(
                    f"{name}: would download {filename} "
                    f"({(size or 0) / 1048576:.1f} MB) and verify sha256"
                )
        say("dry run: no wheel was downloaded or installed")
        return
    paths = [obtain_wheel(*spec) for spec in WHEELS]
    pip_install(py, uv, ["--no-deps", *[str(p) for p in paths]])


def install_custom_node(comfy_root: Path, dry: bool) -> None:
    target = comfy_root / "custom_nodes" / "ComfyUI-Intel-Arc-XPU"
    if target.is_dir():
        say(f"custom node already present at {target}")
        return
    if dry:
        say(f"would clone {REPO_SLUG} into {target}")
        return

    say(f"fetching custom node from {REPO_SLUG}")
    url = f"https://github.com/{REPO_SLUG}/archive/refs/heads/main.zip"
    tmp = HERE / ".custom_node.zip"
    ok = False
    for proxy in PROXIES:
        try:
            urllib.request.urlretrieve(proxy + url, tmp)
            ok = True
            break
        except Exception:  # noqa: BLE001
            continue
    if not ok:
        fail(
            f"could not download the custom node.\n"
            f"  Clone it manually:\n"
            f"    cd {comfy_root / 'custom_nodes'}\n"
            f"    git clone https://github.com/{REPO_SLUG}.git ComfyUI-Intel-Arc-XPU"
        )

    import zipfile

    with zipfile.ZipFile(tmp) as zf:
        zf.extractall(comfy_root / "custom_nodes")
    extracted = comfy_root / "custom_nodes" / f"{REPO_SLUG.split('/')[1]}-main"
    if extracted.is_dir():
        extracted.rename(target)
    tmp.unlink(missing_ok=True)
    say(f"custom node installed at {target}")


def _matches_root(entry: dict, comfy_root: Path) -> bool:
    """True when this installations.json entry owns *comfy_root*."""
    raw = entry.get("installPath")
    if not raw:
        return False
    try:
        declared = Path(raw).resolve()
    except OSError:
        return False
    # installPath is the install root (parent of ComfyUI/), so compare against
    # both the root and its parent to be tolerant of either layout.
    root = comfy_root.resolve()
    return declared == root or declared == root.parent or root.is_relative_to(declared)


def patch_launch_args(comfy_root: Path, dry: bool) -> None:
    """Add the recommended flags to Comfy Desktop's installations.json.

    Only the entry that owns *comfy_root* is touched. Other installations in the
    same file (a separate AI Video install, Comfy Cloud, ...) must not receive
    `--enable-dynamic-vram`: they have no XPU aimdo runtime and would break.
    """
    roaming = Path(os.environ.get("APPDATA", "")) / "Comfy Desktop"
    cfg = roaming / "installations.json"
    if not cfg.is_file():
        say("Comfy Desktop config not found; set launch flags manually:")
        say(f"  {LAUNCH_FLAG_KEEP} {' '.join(LAUNCH_FLAGS_ADD)}")
        return

    try:
        data = json.loads(cfg.read_text(encoding="utf-8-sig"))
    except Exception as exc:  # noqa: BLE001
        say(f"cannot parse {cfg}: {exc}; set launch flags manually")
        return

    if isinstance(data, dict):
        entries = [data]
    elif isinstance(data, list):
        entries = data
    else:
        say("unexpected installations.json shape; set launch flags manually")
        return

    targets = [e for e in entries if _matches_root(e, comfy_root)]
    if not targets:
        say(f"no installations.json entry owns {comfy_root}; set launch flags manually:")
        say(f"  {LAUNCH_FLAG_KEEP} {' '.join(LAUNCH_FLAGS_ADD)}")
        return

    changed = 0
    for entry in targets:
        label = entry.get("name") or entry.get("id") or "?"
        args = entry.get("launchArgs") or ""
        parts = args.split()
        # --enable-manager must survive: it used to get silently dropped
        if LAUNCH_FLAG_KEEP not in parts:
            parts.insert(0, LAUNCH_FLAG_KEEP)
        for i in range(0, len(LAUNCH_FLAGS_ADD), 2):
            flag = LAUNCH_FLAGS_ADD[i]
            value = LAUNCH_FLAGS_ADD[i + 1] if i + 1 < len(LAUNCH_FLAGS_ADD) else None
            if flag not in parts:
                parts.append(flag)
                if value is not None:
                    parts.append(value)
            elif value is not None:
                idx = parts.index(flag)
                if idx + 1 >= len(parts) or parts[idx + 1] != value:
                    if idx + 1 < len(parts) and not parts[idx + 1].startswith("--"):
                        parts[idx + 1] = value
                    else:
                        parts.insert(idx + 1, value)
        new_args = " ".join(parts)
        if new_args != args:
            entry["launchArgs"] = new_args
            changed += 1
            say(f"launchArgs [{label}] -> {new_args}")

    if not changed:
        say("launchArgs already correct")
        return
    if dry:
        say(f"would write {cfg}")
        return
    backup = cfg.with_suffix(".json.arc-turbo.bak")
    if not backup.exists():
        shutil.copy2(cfg, backup)
        say(f"backup written to {backup.name}")
    # no BOM, 2-space indent: mirrors the Electron app's JSON.stringify(x,null,2)
    cfg.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    say(f"wrote {cfg}")


def set_env_vars(dry: bool) -> None:
    if platform.system() != "Windows":
        say("non-Windows: set these environment variables yourself:")
        for k, v in ENV_VARS.items():
            say(f"  {k}={v}")
        return
    for key, value in ENV_VARS.items():
        if dry:
            say(f"would set user env {key}={value}")
            continue
        subprocess.run(["setx", key, value], capture_output=True)
        say(f"set user env {key}={value} (restart ComfyUI to apply)")


def copy_workflow(comfy_root: Path, dry: bool) -> None:
    src = HERE / "workflows" / "Qwen-Image-2.1-MultiRef-BMG-XPU.json"
    if not src.is_file():
        say("workflow file missing, skipping")
        return
    dst_dir = comfy_root / "user" / "default" / "workflows"
    if not dst_dir.is_dir():
        say(f"{dst_dir} not found; copy the workflow manually from {src}")
        return
    dst = dst_dir / src.name
    if dry:
        say(f"would copy workflow to {dst}")
        return
    shutil.copy2(src, dst)
    say(f"workflow copied to {dst}")


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description="ARC BMG XPU Turbo installer")
    ap.add_argument("--dry-run", action="store_true", help="show plan, change nothing")
    ap.add_argument("--skip-torch", action="store_true", help="skip the torch upgrade")
    ap.add_argument(
        "--no-download", action="store_true", help="only use wheels already in ./wheels"
    )
    args = ap.parse_args()

    say("=" * 68)
    say("ARC BMG XPU Turbo installer")
    say("=" * 68)

    # --- environment gate -------------------------------------------------
    # This script only needs *any* Python 3 to run; the version that matters is
    # the one inside ComfyUI's venv, checked further down once we found it.
    if platform.system() != "Windows" or platform.machine() not in ("AMD64", "x86_64"):
        fail("requires Windows x64")
    if sys.version_info < (3, 8):
        fail(
            f"this installer needs Python 3.8+ to run, "
            f"this is {sys.version_info[0]}.{sys.version_info[1]}"
        )

    comfy_root = find_comfy_root()
    py = comfy_python(comfy_root)
    uv = find_uv(comfy_root)
    say(f"ComfyUI:  {comfy_root}")
    say(f"python:   {py}")
    say(f"uv:       {uv or 'not found (will use pip, much slower)'}")

    venv_py_ver = python_version(py)
    if venv_py_ver is None:
        fail(f"cannot run {py}; is the ComfyUI venv intact?")
    if venv_py_ver != TARGET_PY:
        fail(
            f"ComfyUI runs on Python {venv_py_ver[0]}.{venv_py_ver[1]}, "
            f"but the native wheels are cp{TARGET_PY[0]}{TARGET_PY[1]}-only.\n"
            f"  Install a ComfyUI build that uses Python {TARGET_PY[0]}.{TARGET_PY[1]} "
            f"(the official Windows portable / Comfy Desktop builds do).\n"
            f"  Nothing was changed."
        )

    current = torch_version(py)
    if current and not current.endswith("+xpu"):
        if args.skip_torch:
            fail(
                f"torch {current} is not an XPU build, and --skip-torch was given.\n"
                f"  Re-run without --skip-torch to install torch=={TARGET_TORCH}."
            )
        say(f"torch {current} is not an XPU build; it will be replaced")
    if current and current != TARGET_TORCH and not args.skip_torch:
        say(f"torch {current} != {TARGET_TORCH}: a full upgrade is required")

    say("")

    # --- steps ------------------------------------------------------------
    if not args.skip_torch:
        say("[1/5] torch stack")
        install_torch_stack(py, uv, args.dry_run)
    else:
        say("[1/5] torch stack - skipped")

    say("[2/5] omni native wheels")
    if args.no_download:
        say("  --no-download: expecting wheels in ./wheels")
        missing = [f for _, f, _, _ in WHEELS if not (WHEELS_DIR / f).is_file()]
        if missing:
            fail(f"missing wheels: {', '.join(missing)}")
        install_omni_wheels(py, uv, args.dry_run)
    else:
        install_omni_wheels(py, uv, args.dry_run)

    say("[3/5] custom node")
    install_custom_node(comfy_root, args.dry_run)

    say("[4/5] launch flags")
    patch_launch_args(comfy_root, args.dry_run)
    set_env_vars(args.dry_run)

    say("[5/5] workflow")
    copy_workflow(comfy_root, args.dry_run)

    say("")
    say("=" * 68)
    if args.dry_run:
        say("dry run complete, nothing was changed")
    else:
        say("done. restart ComfyUI, then open the workflow:")
        say("  Qwen-Image-2.1-MultiRef-BMG-XPU")
        say("")
        say("verify it worked: run the workflow once and check the")
        say("'OmniXPU 状态' node shows 'Attention calls: cute=... torch=0'")
    say("=" * 68)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
