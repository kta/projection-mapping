# MVP実装ガイド(マイルストーンM0)

**ゴール**: iPadの画面上で、1枚の画像(テストグリッド)の4隅を指でドラッグし、リアルタイムに射影変換される最小アプリを動かす。外部ディスプレイ・動画・3面分割はまだ扱わない。

これは要件定義書 §11 の **M0** に対応し、以下を検証するための最短コードである:
- `CIPerspectiveTransform` で意図通りのワープができること
- ドラッグ→再描画のレイテンシが体感リアルタイムであること
- 正規化座標/UI座標/Core Image座標の変換設計(アーキテクチャ設計書 §2)が正しいこと

---

## 1. プロジェクト作成手順

1. Xcode → New Project → **iOS App**、Interface: **SwiftUI**、名前は `CornerCast` など。
2. Deployment Target: **iPadOS 17.0**、Devices: **iPad**。
3. 下記2ファイルを追加するだけで動く(アセット不要。テスト画像はコードで生成する)。

---

## 2. サンプル実装(全文)

### `Quad.swift` — ドメインモデル

```swift
import CoreGraphics

/// 射影変換先の四角形。座標はキャンバスに対する正規化座標(0–1)、左上原点。
struct Quad: Equatable {
    var topLeft:     CGPoint
    var topRight:    CGPoint
    var bottomRight: CGPoint
    var bottomLeft:  CGPoint

    static let initial = Quad(
        topLeft:     CGPoint(x: 0.15, y: 0.15),
        topRight:    CGPoint(x: 0.85, y: 0.10),
        bottomRight: CGPoint(x: 0.90, y: 0.85),
        bottomLeft:  CGPoint(x: 0.10, y: 0.90)
    )

    enum Corner: CaseIterable { case topLeft, topRight, bottomRight, bottomLeft }

    subscript(_ c: Corner) -> CGPoint {
        get {
            switch c {
            case .topLeft: topLeft
            case .topRight: topRight
            case .bottomRight: bottomRight
            case .bottomLeft: bottomLeft
            }
        }
        set {
            // キャンバス外へ逃げないよう0–1にクランプ
            let p = CGPoint(x: min(max(newValue.x, 0), 1),
                            y: min(max(newValue.y, 0), 1))
            switch c {
            case .topLeft: topLeft = p
            case .topRight: topRight = p
            case .bottomRight: bottomRight = p
            case .bottomLeft: bottomLeft = p
            }
        }
    }
}
```

### `WarpRenderer.swift` — Core Imageによる射影変換

```swift
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// テストグリッド画像を生成し、Quadに従って射影変換した結果を返す。
/// UIフレームワーク非依存の「Engine層」に相当(将来M1/M2でそのまま流用する)。
final class WarpRenderer {
    private let context = CIContext()           // 再利用必須(毎回生成すると激重)
    private let source: CIImage

    init() {
        source = Self.makeTestGrid(size: CGSize(width: 1200, height: 900))
    }

    /// - Parameters:
    ///   - quad: 正規化座標(左上原点)の変換先四角形
    ///   - canvasSize: 表示キャンバスのサイズ(pt)
    ///   - scale: 画面スケール(Retinaなら2〜3)
    func render(quad: Quad, canvasSize: CGSize, scale: CGFloat) -> UIImage? {
        let px = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        guard px.width > 0, px.height > 0 else { return nil }

        // 1) ソースをキャンバスのピクセルサイズへスケール
        let sx = px.width / source.extent.width
        let sy = px.height / source.extent.height
        let scaled = source.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        // 2) 射影変換(4点補正)。Core Imageは左下原点なのでYを反転する
        func toCI(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * px.width, y: (1 - p.y) * px.height)
        }
        let f = CIFilter.perspectiveTransform()
        f.inputImage  = scaled
        f.topLeft     = toCI(quad.topLeft)
        f.topRight    = toCI(quad.topRight)
        f.bottomRight = toCI(quad.bottomRight)
        f.bottomLeft  = toCI(quad.bottomLeft)
        guard let warped = f.outputImage else { return nil }

        // 3) 黒背景キャンバスへ合成(M2では3面をここでreduce合成する)
        let canvasRect = CGRect(origin: .zero, size: px)
        let composed = warped.composited(over: CIImage(color: .black).cropped(to: canvasRect))

        guard let cg = context.createCGImage(composed, from: canvasRect) else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    /// 白地に格子+外周枠+対角線のテストパターンを生成(アセット不要)
    private static func makeTestGrid(size: CGSize) -> CIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let c = ctx.cgContext
            UIColor.white.setFill()
            c.fill(CGRect(origin: .zero, size: size))

            UIColor.systemCyan.setStroke()
            c.setLineWidth(2)
            let step: CGFloat = 100
            stride(from: 0, through: size.width, by: step).forEach {
                c.move(to: CGPoint(x: $0, y: 0)); c.addLine(to: CGPoint(x: $0, y: size.height))
            }
            stride(from: 0, through: size.height, by: step).forEach {
                c.move(to: CGPoint(x: 0, y: $0)); c.addLine(to: CGPoint(x: size.width, y: $0))
            }
            c.strokePath()

            UIColor.systemRed.setStroke()
            c.setLineWidth(8)
            c.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4))
            c.move(to: .zero); c.addLine(to: CGPoint(x: size.width, y: size.height))
            c.move(to: CGPoint(x: size.width, y: 0)); c.addLine(to: CGPoint(x: 0, y: size.height))
            c.strokePath()
        }
        return CIImage(image: img)!
    }
}
```

### `ContentView.swift` — 編集UI

```swift
import SwiftUI

struct ContentView: View {
    @State private var quad = Quad.initial
    @State private var rendered: UIImage?
    private let renderer = WarpRenderer()

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color(white: 0.1).ignoresSafeArea()

                if let rendered {
                    Image(uiImage: rendered)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                }

                // ワイヤーフレーム(四角形の輪郭)
                Path { p in
                    p.move(to: point(quad.topLeft, in: size))
                    p.addLine(to: point(quad.topRight, in: size))
                    p.addLine(to: point(quad.bottomRight, in: size))
                    p.addLine(to: point(quad.bottomLeft, in: size))
                    p.closeSubpath()
                }
                .stroke(.yellow.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4]))

                // 4隅のコントロールポイント
                ForEach(Quad.Corner.allCases, id: \.self) { corner in
                    handle(for: corner, in: size)
                }
            }
            .onAppear { render(size) }
            .onChange(of: quad) { render(size) }
            .onChange(of: size) { render(size) }
        }
        .statusBarHidden()
    }

    private func handle(for corner: Quad.Corner, in size: CGSize) -> some View {
        Circle()
            .fill(.yellow)
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(.black, lineWidth: 1))
            // タッチ判定は視覚サイズより大きく取る(F-UI-1)
            .contentShape(Circle().inset(by: -16))
            .position(point(quad[corner], in: size))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        quad[corner] = CGPoint(x: value.location.x / size.width,
                                               y: value.location.y / size.height)
                    }
            )
    }

    private func point(_ normalized: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }

    private func render(_ size: CGSize) {
        rendered = renderer.render(quad: quad,
                                   canvasSize: size,
                                   scale: UIScreen.main.scale)
    }
}

#Preview { ContentView() }
```

---

## 3. 動作確認の観点(M0のDefinition of Done)

- [ ] 4つの●をドラッグすると、グリッド画像が追従して台形/自由四角形に歪む
- [ ] 対角線が「折れずに」直線のまま歪む(=射影補間が正しい。三角形分割方式ならここで折れる)
- [ ] ドラッグ中のカクつきが体感されない(iPad実機で確認)
- [ ] 点をキャンバス外へドラッグしても0–1にクランプされ、クラッシュしない

## 4. 既知の割り切り(M0限定)と次の一歩

| 割り切り | 本実装(M1以降)での置き換え |
|---|---|
| `createCGImage` でUIImage化(毎ドラッグでCPUへ転送) | `CIContext.render(to: MTLTexture)` + `CAMetalLayer` でGPU完結(設計書§3.3) |
| 描画トリガが `onChange`(SwiftUI再評価駆動) | `CADisplayLink` 駆動の `OutputRenderer` |
| Quadを `@State` で直接保持 | `MappingViewModel` に集約し、3面ぶんの `MappingPreset` へ拡張 |
| 1メッシュのみ | `Surface` enum × 3 の `ForEach` に一般化(モデルは既に対応可能な形) |

**M1への具体的な次タスク**(要件定義書§11):
1. 上記コードのQuadを `[Surface: SurfaceConfig]` に拡張し、3メッシュ化
2. `UIApplicationDelegateAdaptor` + 外部ディスプレイシーン対応(設計書§4)— **最初に実機スパイクを行うこと(リスクR5)**
3. テストパターンを面ごとの色分け+ラベル付きに変更(F-UI-2)
