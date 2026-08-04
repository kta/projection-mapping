#!/usr/bin/env python3
"""同梱サンプル動画(F-SRC-7)の実体検査。

tools/make_samples.py が生成した動画が、アプリの前提を実際に満たしているかを
デコードして数値で確かめる。コードを読むだけでは分からないことだけを見る。

  1. 仕様どおりか        1920x1080 / 30fps / 12秒 / 360フレーム、全フレームがデコードできる
  2. ループが継ぎ目なしか 最終フレーム→先頭フレームの差が、通常の隣接フレーム差と同程度か
                         (make_samples.py は周期関数のみで構成しループ境界なしと称している)
  3. 各面に絵があるか    デフォルトクロップ(F-CROP-1)で切り出した左壁/正面壁/床の各領域が
                         真っ黒・のっぺりでないか。無地だと投影しても何も見えない

必要: pip install numpy imageio-ffmpeg
実行: python3 tools/verify_samples.py
"""
import os
import subprocess
import sys

import numpy as np
import imageio_ffmpeg

W, H, FPS, DUR = 1920, 1080, 30, 12
N = FPS * DUR

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SRC = os.path.join(ROOT, "CornerCast", "Resources", "SampleVideos")

SAMPLES = ["warp-drive", "gentle-ocean", "firefly-forest"]

# Models.swift makeDefault() のデフォルトクロップ(正規化・左上原点)を px へ。
#   leftWall  x:0,   y:0,   w:1/3, h:0.7
#   frontWall x:1/3, y:0,   w:1/3, h:0.7
#   floor     x:1/3, y:0.7, w:1/3, h:0.3
FACES = {
    "左壁":   (0,              0,             W // 3,     int(H * 0.7)),
    "正面壁": (W // 3,         0,             W * 2 // 3, int(H * 0.7)),
    "床":     (W // 3,         int(H * 0.7),  W * 2 // 3, H),
}

# ループ継ぎ目の判定しきい値。継ぎ目の差が「隣接フレーム差の中央値 x この倍率」を
# 超えたら、目に見えるジャンプがあると判断する。
SEAM_RATIO_LIMIT = 3.0

# 明るさの判定(0-255)。プロジェクタは黒を「光を出さない」でしか表現できないので、
# 暗い映像は暗いのではなく「見えない」になる。単純な平均輝度では
# 星空(黒地に光点)を誤判定するため、明るい画素がどれだけ載っているかで見る。
BRIGHT_LEVEL = 64          # これ以上を「投影して視認できる画素」とみなす
BRIGHT_COVER_OK = 2.0      # 明るい画素が全体の何%以上あれば十分か
BRIGHT_COVER_MIN = 0.05    # これ未満なら、その面には実質何も映らない
PEAK_MIN = 96              # 最大輝度がこれ未満なら光点すら弱い

GRN, RED, YLW, DIM, RST = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"
failed = False


def pass_(msg):
    print(f"{GRN}  PASS{RST} {msg}")


def fail_(msg):
    global failed
    failed = True
    print(f"{RED}  FAIL{RST} {msg}")


def warn_(msg):
    print(f"{YLW}  WARN{RST} {msg}")


def info_(msg):
    print(f"{DIM}       {msg}{RST}")


def probe(path):
    """ffmpeg にデコードさせてメタ情報を取る。"""
    exe = imageio_ffmpeg.get_ffmpeg_exe()
    r = subprocess.run([exe, "-v", "info", "-i", path, "-f", "null", "-"],
                       capture_output=True, text=True)
    meta = {}
    for line in r.stderr.splitlines():
        s = line.strip()
        if s.startswith("Duration:"):
            meta["duration"] = s.split("Duration:")[1].split(",")[0].strip()
        if "Video:" in s and "Stream #" in s:
            meta["stream"] = s
        if s.startswith("frame="):
            try:
                meta["frames"] = int(s.split("frame=")[1].split()[0])
            except (IndexError, ValueError):
                pass
    meta["stderr"] = r.stderr
    return meta


def frames(path):
    """rawvideo(gray)で1フレームずつ流す。全フレームを同時に持たない。"""
    exe = imageio_ffmpeg.get_ffmpeg_exe()
    p = subprocess.Popen(
        [exe, "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "gray", "-"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    size = W * H
    try:
        while True:
            buf = p.stdout.read(size)
            if len(buf) < size:
                break
            yield np.frombuffer(buf, np.uint8).reshape(H, W)
    finally:
        p.stdout.close()
        p.wait()


def check(name):
    path = os.path.join(SRC, f"{name}.mp4")
    print(f"\n\033[1m-- {name}.mp4 --\033[0m")

    if not os.path.exists(path):
        fail_(f"ファイルが無い: {path}")
        return
    info_(f"{os.path.getsize(path):,} bytes")

    # 1) 仕様どおりか -------------------------------------------------------
    meta = probe(path)
    stream = meta.get("stream", "")
    if f"{W}x{H}" in stream:
        pass_(f"解像度 {W}x{H}")
    else:
        fail_(f"解像度が {W}x{H} でない: {stream}")
    if f"{FPS} fps" in stream:
        pass_(f"{FPS} fps")
    else:
        fail_(f"{FPS} fps でない: {stream}")
    if meta.get("frames") == N:
        pass_(f"全 {N} フレームをデコードできた(尺 {meta.get('duration')})")
    else:
        fail_(f"フレーム数が {N} でない: {meta.get('frames')} "
              f"(デコード途中で破損している可能性)")

    # 2) ループ継ぎ目 + 3) 面ごとの絵 を1パスで ------------------------------
    first = None
    prev = None
    last = None
    diffs = []                                            # 隣接フレーム差(平均絶対誤差)
    hist = {k: np.zeros(256, np.int64) for k in FACES}     # 面ごとの輝度ヒストグラム
    count = 0

    for f in frames(path):
        f32 = f.astype(np.float32)
        if first is None:
            first = f32.copy()
        else:
            diffs.append(float(np.mean(np.abs(f32 - prev))))
        # 面ごとの輝度分布は10フレームおきに積めば十分
        if count % 10 == 0:
            for label, (x0, y0, x1, y1) in FACES.items():
                region = f[y0:y1, x0:x1]
                hist[label] += np.bincount(region.ravel(), minlength=256)
        prev = f32
        last = f32
        count += 1

    if count == 0:
        fail_("1フレームもデコードできなかった")
        return

    seam = float(np.mean(np.abs(first - last)))
    typical = float(np.median(diffs)) if diffs else 0.0
    worst = float(np.max(diffs)) if diffs else 0.0
    info_(f"隣接フレーム差 中央値 {typical:.3f} / 最大 {worst:.3f} "
          f"(0-255スケール、以下同じ)")

    if typical <= 0:
        warn_("隣接フレーム差が0。動きのない静止動画かもしれない")
    elif seam <= typical * SEAM_RATIO_LIMIT:
        pass_(f"ループ継ぎ目なし: 末尾→先頭の差 {seam:.3f} "
              f"(通常の隣接差 {typical:.3f} の {seam / typical:.2f}倍)")
    else:
        fail_(f"ループで飛ぶ: 末尾→先頭の差 {seam:.3f} は "
              f"通常の隣接差 {typical:.3f} の {seam / typical:.1f}倍。"
              f"繰り返し再生時に継ぎ目が見える")

    levels = np.arange(256)
    for label, h in hist.items():
        total = int(h.sum())
        mean = float((h * levels).sum() / total)
        cover = 100.0 * float(h[BRIGHT_LEVEL:].sum()) / total
        peak = int(np.max(np.nonzero(h)[0]))
        desc = f"平均輝度 {mean:.1f} / 輝度{BRIGHT_LEVEL}超の画素 {cover:.2f}% / 最大 {peak}"

        if cover < BRIGHT_COVER_MIN or peak < PEAK_MIN:
            fail_(f"{label}: この面には実質何も映らない({desc})")
        elif cover < BRIGHT_COVER_OK:
            warn_(f"{label}: 投影すると相当暗い({desc})。"
                  f"明るい画素がまばらなので、"
                  f"明るい部屋や輝度の低いプロジェクタではほぼ見えない")
        else:
            pass_(f"{label}: 十分に見える({desc})")


def main():
    print("\033[1m同梱サンプル動画の検査\033[0m")
    info_(f"対象: {os.path.relpath(SRC, ROOT)}")
    info_("クロップは Models.swift makeDefault() のデフォルト値(F-CROP-1)に一致させてある")
    for name in SAMPLES:
        check(name)
    print()
    if failed:
        print(f"{RED}サンプル動画に問題あり{RST}")
        return 1
    print(f"{GRN}サンプル動画は健全{RST}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
