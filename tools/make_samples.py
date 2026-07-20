#!/usr/bin/env python3
"""CornerCast同梱サンプル動画ジェネレータ。

3本の 1920x1080 / 30fps / 12秒 のシームレスループ動画を
CornerCast/Resources/SampleVideos/ に生成する。

構図はデフォルトクロップ(F-CROP-1 / Models.makeDefault)に合わせてある:
  - 左壁   = 左1/3 x 上段70%   (x 0-640,    y 0-756)
  - 正面壁 = 中央1/3 x 上段70% (x 640-1280, y 0-756)
  - 床     = 中央1/3 x 下段30% (x 640-1280, y 756-1080)
どの領域を切り出しても成立するよう、全画面を1つのシーンとして描く。

すべてのアニメーションは t∈[0,1) の周期関数のみで構成し、
最終フレームの次が先頭フレームに完全連続する(ループ境界なし)。

実行: pip install numpy imageio-ffmpeg && python3 tools/make_samples.py
"""
import os
import numpy as np
import imageio_ffmpeg

W, H, FPS, DUR = 1920, 1080, 30, 12
N = FPS * DUR
OUT_DIR = os.path.join(os.path.dirname(__file__), "..",
                       "CornerCast", "Resources", "SampleVideos")

# 前壁ゾーンの中心(消失点や太陽の位置に使う)
FRONT_CX, FRONT_CY = 960.0, 378.0

YY, XX = np.mgrid[0:H, 0:W].astype(np.float32)


# ---------------------------------------------------------------- 共通ヘルパー

def make_kernel(r: int) -> np.ndarray:
    y, x = np.mgrid[-r:r + 1, -r:r + 1]
    return np.exp(-(x * x + y * y) / (2 * (r / 2.5) ** 2)).astype(np.float32)


KERNELS = {r: make_kernel(r) for r in (2, 3, 4, 6, 9, 14, 22, 34)}


def splat(img: np.ndarray, cx: float, cy: float, r: int, color, inten: float):
    """ガウス光点を加算合成する(はみ出しはクリップ)。"""
    k = KERNELS[r]
    x0, y0 = int(cx) - r, int(cy) - r
    x1, y1 = x0 + k.shape[1], y0 + k.shape[0]
    kx0, ky0 = max(0, -x0), max(0, -y0)
    kx1 = k.shape[1] - max(0, x1 - W)
    ky1 = k.shape[0] - max(0, y1 - H)
    if kx0 >= kx1 or ky0 >= ky1:
        return
    patch = k[ky0:ky1, kx0:kx1, None] * (np.asarray(color, np.float32) * inten)
    img[max(0, y0):min(H, y1), max(0, x0):min(W, x1)] += patch


def write_video(name: str, frames):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name)
    # macro_block_size=1: 1080は16の倍数でないため、既定だと1088へ勝手に
    # リサイズされてしまう。H.264は内部cropで1080を正しく扱えるので無効化する。
    gen = imageio_ffmpeg.write_frames(
        path, (W, H), fps=FPS, codec="libx264", macro_block_size=1,
        output_params=["-crf", "22", "-preset", "medium",
                       "-pix_fmt", "yuv420p", "-movflags", "+faststart"])
    gen.send(None)
    for i, img in enumerate(frames):
        gen.send((np.clip(img, 0.0, 1.0) * 255).astype(np.uint8).tobytes())
        if i % 60 == 0:
            print(f"  {name}: frame {i}/{N}")
    gen.close()
    print(f"  -> {path} ({os.path.getsize(path) / 1e6:.1f} MB)")


# ---------------------------------------------------------------- ① ワープ航行

def warp_frames():
    """正面壁の中心を消失点に、星が手前へ流れるワープ演出。

    各星は位相 s=(p+t) mod 1 で中心から指数的に離れ、画面外(>1400px)で
    消えてから中心で再出現するので、ループ境界は画面外で起きる=シームレス。
    """
    rng = np.random.default_rng(7)
    n = 420
    ang = rng.uniform(0, 2 * np.pi, n)
    phase = rng.uniform(0, 1, n)
    warm = rng.uniform(0, 1, n) < 0.15
    d = np.sqrt((XX - FRONT_CX) ** 2 + (YY - FRONT_CY) ** 2)
    nebula = np.exp(-d / 420.0)[..., None]
    base = np.array([0.05, 0.075, 0.15], np.float32)

    for f in range(N):
        t = f / N
        pulse = 0.85 + 0.15 * np.sin(2 * np.pi * t)      # 周期1でシームレス
        img = (nebula * (base * pulse)).astype(np.float32)
        for i in range(n):
            s = (phase[i] + t) % 1.0
            dist = 14.0 + (s ** 2.0) * 1500.0
            if dist > 1400.0:
                continue                                  # 画面外(ループ縫い目)
            bright = min(1.0, 0.15 + s * 1.6)
            col = (1.0, 0.85, 0.7) if warm[i] else (0.75, 0.85, 1.0)
            dx, dy = np.cos(ang[i]), np.sin(ang[i])
            streak = 6.0 + s * 70.0                       # 速度感のある尾
            for j in range(5):
                rr = dist - streak * j / 5.0
                if rr <= 0:
                    continue
                px, py = FRONT_CX + dx * rr, FRONT_CY + dy * rr
                if not (-40 <= px <= W + 40 and -40 <= py <= H + 40):
                    continue
                splat(img, px, py, 3 if s > 0.5 else 2, col,
                      bright * (1.0 - 0.16 * j))
        yield img


# ---------------------------------------------------------------- ② 夕なぎの海

def ocean_frames():
    """壁ゾーンに夕暮れの空と海、床ゾーンにゆらめく水面。パステルで優しく。"""
    horizon = 470.0
    rng = np.random.default_rng(11)

    # 空: 上(ラベンダー)→水平線(あたたかいピーチ)のグラデーション
    v = np.clip(YY / horizon, 0, 1)[..., None]
    sky_top = np.array([0.42, 0.40, 0.62], np.float32)
    sky_hor = np.array([0.95, 0.66, 0.50], np.float32)
    sky = sky_top * (1 - v) + sky_hor * v

    # 太陽(正面壁の中央あたり)
    d_sun = np.sqrt((XX - FRONT_CX) ** 2 + (YY - 340.0) ** 2)
    sun_glow = np.exp(-d_sun / 190.0)[..., None] * np.array([0.55, 0.33, 0.16], np.float32)
    sun_core = np.exp(-(d_sun / 46.0) ** 2)[..., None] * np.array([0.9, 0.75, 0.55], np.float32)

    # 海: 水平線(明るい)→手前(深いティール)
    w = np.clip((YY - horizon) / (H - horizon), 0, 1)[..., None]
    sea_top = np.array([0.80, 0.55, 0.45], np.float32)   # 水平線は空を映す
    sea_bot = np.array([0.05, 0.22, 0.28], np.float32)
    sea = sea_top * (1 - w ** 0.6) + sea_bot * w ** 0.6
    above = (YY < horizon)[..., None]

    # きらめき(固定点が正弦で明滅=シームレス)
    n_sp = 260
    spx = rng.uniform(0, W, n_sp)
    spy = rng.uniform(horizon + 8, H - 4, n_sp)
    spk = rng.integers(1, 4, n_sp)          # 明滅周期(整数=ループ可)
    spp = rng.uniform(0, 1, n_sp)

    yn = np.clip((YY - horizon) / (H - horizon), 1e-4, 1)  # 手前ほど1

    for f in range(N):
        t = f / N
        # 波: xに周期的な縞を整数サイクルで流す(すべて周期1の関数)
        ripple = (
            0.05 * np.sin(2 * np.pi * (XX / 480.0 + 2 * t) + YY * 0.035)
            + 0.04 * np.sin(2 * np.pi * (XX / 260.0 - 3 * t) + YY * 0.06)
            + 0.03 * np.sin(2 * np.pi * (YY / 90.0 - 4 * t))
        ) * (0.35 + 0.65 * yn)
        # 床ゾーン寄りの大きなうねり(コースティック風)
        caustic = np.abs(
            np.sin(2 * np.pi * (XX / 340.0 + 1 * t)
                   + 2.4 * np.sin(2 * np.pi * (YY / 420.0 - 1 * t)))
        ) * np.clip((YY - 700.0) / 240.0, 0, 1)
        water_l = (ripple + 0.16 * caustic)[..., None] * np.array([0.5, 0.9, 0.85], np.float32)

        img = np.where(above, sky, sea + water_l) + sun_glow + sun_core
        img = img.astype(np.float32)
        for i in range(n_sp):
            b = 0.5 + 0.5 * np.sin(2 * np.pi * (spk[i] * t + spp[i]))
            splat(img, spx[i], spy[i], 2, (1.0, 0.85, 0.65), 0.5 * b * b)
        yield img


# ---------------------------------------------------------------- ③ ホタルの森

def firefly_frames():
    """夜の森。左壁に月、全面にホタルの光、床ゾーンに淡い霧。"""
    rng = np.random.default_rng(23)

    # 背景: 紺→深緑の夜のグラデーション
    v = (YY / H)[..., None]
    top = np.array([0.015, 0.03, 0.09], np.float32)
    bot = np.array([0.03, 0.09, 0.06], np.float32)
    bg = top * (1 - v) + bot * v

    # 月(左壁ゾーン)
    d_moon = np.sqrt((XX - 320.0) ** 2 + (YY - 185.0) ** 2)
    moon = (np.exp(-(d_moon / 34.0) ** 2) * 0.9
            + np.exp(-d_moon / 150.0) * 0.22)[..., None] * np.array([0.85, 0.88, 0.8], np.float32)

    # 木のシルエット(静止。ゆるく波打つ幹)
    trees = np.zeros((H, W), np.float32)
    for tx, tw, ph in [(80, 46, 0.0), (560, 34, 2.1), (1180, 40, 4.2),
                       (1500, 60, 1.3), (1840, 50, 3.0)]:
        cx = tx + 26.0 * np.sin(YY / 150.0 + ph)
        trees += np.clip(1.0 - np.abs(XX - cx) / (tw * (0.7 + 0.6 * v[..., 0])), 0, 1)
    shade = np.clip(trees, 0, 1)[..., None] * 0.85

    # 床ゾーンの霧(周期ドリフト)
    mist_mask = np.clip((YY - 720.0) / 200.0, 0, 1)

    # ホタル: リサージュ軌道(整数周波数)+整数周期の明滅=完全ループ
    n_ff = 90
    ax = rng.uniform(30, 90, n_ff)
    ay = rng.uniform(20, 60, n_ff)
    fx = rng.integers(1, 3, n_ff)
    fy = rng.integers(1, 3, n_ff)
    p1 = rng.uniform(0, 1, n_ff)
    p2 = rng.uniform(0, 1, n_ff)
    pk = rng.integers(2, 5, n_ff)
    pp = rng.uniform(0, 1, n_ff)
    # 中央と床寄りに多めに配置
    cxs = rng.uniform(40, W - 40, n_ff)
    cys = np.concatenate([rng.uniform(120, 740, n_ff - 30),
                          rng.uniform(740, 1040, 30)])

    for f in range(N):
        t = f / N
        mist = (0.05 + 0.03 * np.sin(2 * np.pi * (XX / 640.0 + 1 * t))
                + 0.02 * np.sin(2 * np.pi * (XX / 300.0 - 2 * t))) * mist_mask
        img = bg * (1.0 - shade) + moon + mist[..., None] * np.array([0.4, 0.7, 0.6], np.float32)
        img = img.astype(np.float32)
        for i in range(n_ff):
            px = cxs[i] + ax[i] * np.sin(2 * np.pi * (fx[i] * t + p1[i]))
            py = cys[i] + ay[i] * np.sin(2 * np.pi * (fy[i] * t + p2[i]))
            blink = 0.5 + 0.5 * np.sin(2 * np.pi * (pk[i] * t + pp[i]))
            b = blink ** 3
            if b < 0.02:
                continue
            splat(img, px, py, 9, (0.55, 0.9, 0.35), 0.28 * b)   # ハロー
            splat(img, px, py, 3, (0.95, 1.0, 0.6), 0.9 * b)     # コア
        yield img


# ---------------------------------------------------------------- main

if __name__ == "__main__":
    print("generating warp-drive.mp4 (ワープ航行)")
    write_video("warp-drive.mp4", warp_frames())
    print("generating gentle-ocean.mp4 (夕なぎの海)")
    write_video("gentle-ocean.mp4", ocean_frames())
    print("generating firefly-forest.mp4 (ホタルの森)")
    write_video("firefly-forest.mp4", firefly_frames())
    print("done")
