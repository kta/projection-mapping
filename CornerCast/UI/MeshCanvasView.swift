import SwiftUI
import Foundation

/// メッシュ編集キャンバス(F-UI-1)。
/// 3面のワイヤーフレーム+12個のコントロールポイントを描画し、ドラッグで頂点を動かす。
///
/// 実装方針(TASK UI-1):
/// - GeometryReaderで自サイズを取得し、出力アスペクト(16:9)のレターボックス矩形を中央に置く。
/// - 各Surfaceのquadを Path で描画(選択中の面はハイライト)。識別色はTestPatternと同じ
///   (左壁=シアン/正面壁=マゼンタ/床=イエロー)。
/// - コントロールポイント: 見た目20pt・タッチ判定44pt(44×44のframe+contentShape)。
/// - 座標変換は CoordinateMapper 経由のみ(手計算・Y反転の直書き禁止)。
struct MeshCanvasView: View {
    @Bindable var viewModel: MappingViewModel

    /// ドラッグ判定に使う座標空間名。
    private static let space = "CornerCast.canvas"
    /// 合成プレビュー(F-OUT-4)。EditorPreviewRendererがデバウンス付きで更新する。
    @State private var previewImage: UIImage?
    /// 面全体ドラッグ(F-UI-7)のジェスチャ開始時quad
    @State private var surfaceDragBase: [Surface: Quad] = [:]

    var body: some View {
        GeometryReader { geo in
            let canvasRect = Self.letterboxRect(in: geo.size)
            ZStack {
                Color.black
                // 合成プレビュー(F-OUT-4): 出力と同じFrameComposerを低解像度で回した結果。
                // 外部ディスプレイ未接続でも、投影される絵をここで確認できる。
                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .frame(width: canvasRect.width, height: canvasRect.height)
                        .position(x: canvasRect.midX, y: canvasRect.midY)
                }
                Rectangle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    .frame(width: canvasRect.width, height: canvasRect.height)
                    .position(x: canvasRect.midX, y: canvasRect.midY)

                // 3面ワイヤーフレーム(drawOrder順に下から描画)
                ForEach(Surface.drawOrder, id: \.self) { s in
                    if let quad = viewModel.preset.surfaces[s]?.quad {
                        let selected = viewModel.selectedSurface == s
                        // 面の内側をドラッグすると面全体を平行移動(F-UI-7)。
                        // ほぼ透明のfillでヒット領域を作る(コントロールポイントは
                        // ZStackの後段にあるため点のドラッグが優先される)。
                        quadPath(quad, in: canvasRect)
                            .fill(Color.white.opacity(0.001))
                            .gesture(surfaceDragGesture(s, canvasRect: canvasRect))
                            .allowsHitTesting(!viewModel.isEditLocked)
                        quadPath(quad, in: canvasRect)
                            .stroke(color(for: s),
                                    style: StrokeStyle(lineWidth: selected ? 3 : 1.5,
                                                       lineJoin: .round))
                            .opacity(viewModel.isEditLocked ? 0.5 : 1)
                        // 面ラベル
                        Text(s.displayName)
                            .font(.caption2)
                            .foregroundStyle(color(for: s))
                            .position(centroid(quad, in: canvasRect))
                    }
                }

                // 12個のコントロールポイント
                ForEach(Surface.allCases) { s in
                    ForEach(Quad.Corner.allCases) { c in
                        ControlPoint(
                            viewModel: viewModel,
                            surface: s,
                            corner: c,
                            canvasRect: canvasRect,
                            color: color(for: s),
                            spaceName: Self.space
                        )
                    }
                }
            }
            .coordinateSpace(name: Self.space)
            // ハードウェアキーボード微調整: 矢印=±1px、Shift+矢印=±10px
            // (iPadの外付けキーボード / Mac Catalyst向け)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress { press in
                handleKeyPress(press)
            }
            .task(id: previewKey) {
                // 連続ドラッグ中の再描画を間引く(120msデバウンス)。
                // .task(id:) はキー変化時に前回タスクを自動キャンセルする。
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                previewImage = EditorPreviewRenderer.shared.render(
                    preset: viewModel.preset,
                    content: viewModel.contentSource,
                    size: CGSize(width: 640, height: 360))
            }
        }
        .background(Color.black)
    }

    /// 面全体の平行移動ジェスチャ(F-UI-7)
    private func surfaceDragGesture(_ s: Surface, canvasRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                viewModel.selectedSurface = s
                if surfaceDragBase[s] == nil {
                    viewModel.beginGesture()   // 1ジェスチャ=1アンドゥ単位
                    surfaceDragBase[s] = viewModel.preset.surfaces[s]?.quad
                }
                guard let base = surfaceDragBase[s], canvasRect.width > 0 else { return }
                let delta = CGPoint(x: value.translation.width / canvasRect.width,
                                    y: value.translation.height / canvasRect.height)
                viewModel.translate(surface: s, by: delta, from: base)
            }
            .onEnded { _ in surfaceDragBase[s] = nil }
    }

    /// 矢印キーによる微調整(選択中の頂点が対象)
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard let s = viewModel.selectedSurface, let c = viewModel.selectedCorner,
              !viewModel.isEditLocked else { return .ignored }
        let step: Double = press.modifiers.contains(.shift) ? 10 : 1
        switch press.key {
        case .upArrow:
            viewModel.nudge(corner: c, of: s, dx: 0, dy: -step)
        case .downArrow:
            viewModel.nudge(corner: c, of: s, dx: 0, dy: step)
        case .leftArrow:
            viewModel.nudge(corner: c, of: s, dx: -step, dy: 0)
        case .rightArrow:
            viewModel.nudge(corner: c, of: s, dx: step, dy: 0)
        default:
            return .ignored
        }
        return .handled
    }

    /// プレビュー再描画のトリガキー(ワープ結果に影響する状態のみ)
    private var previewKey: String {
        viewModel.preset.calibrationFingerprint + "|" + Self.contentKey(viewModel.contentSource)
    }

    private static func contentKey(_ c: MappingViewModel.ContentSource) -> String {
        switch c {
        case .none: return "none"
        case .testPattern: return "testPattern"
        case .image(let url): return "image:\(url.absoluteString)"
        case .video(let url): return "video:\(url.absoluteString)"
        case .bakedVideo(let url): return "baked:\(url.absoluteString)"
        }
    }

    // MARK: - 描画ヘルパー

    /// 面の識別色(TestPatternGeneratorと一致させる)
    private func color(for s: Surface) -> Color {
        switch s {
        case .leftWall: return .cyan
        case .frontWall: return Color(red: 1, green: 0, blue: 1) // マゼンタ
        case .floor: return .yellow
        }
    }

    /// 正規化Quad → キャンバス内UI座標のPath
    private func quadPath(_ q: Quad, in rect: CGRect) -> Path {
        var path = Path()
        let pts = [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft]
            .map { Self.uiPoint($0, in: rect) }
        guard let first = pts.first else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    private func centroid(_ q: Quad, in rect: CGRect) -> CGPoint {
        let pts = [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft]
            .map { Self.uiPoint($0, in: rect) }
        let sx = pts.reduce(0) { $0 + $1.x }
        let sy = pts.reduce(0) { $0 + $1.y }
        return CGPoint(x: sx / 4, y: sy / 4)
    }

    /// 正規化座標(0-1) → キャンバス内UI座標(レターボックスのオフセット込み)
    static func uiPoint(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        let local = CoordinateMapper.ui(fromNormalized: p, in: rect.size)
        return CGPoint(x: rect.origin.x + local.x, y: rect.origin.y + local.y)
    }

    /// キャンバス内UI座標 → 正規化座標
    static func normalized(_ ui: CGPoint, in rect: CGRect) -> CGPoint {
        let local = CGPoint(x: ui.x - rect.origin.x, y: ui.y - rect.origin.y)
        return CoordinateMapper.normalized(fromUI: local, in: rect.size)
    }

    /// 16:9レターボックス矩形をコンテナ中央に配置
    static func letterboxRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let target: CGFloat = 16.0 / 9.0
        let w: CGFloat
        let h: CGFloat
        if size.width / size.height > target {
            h = size.height
            w = h * target
        } else {
            w = size.width
            h = w / target
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

// MARK: - コントロールポイント(1頂点)

/// 1つのコントロールポイント。ドラッグで viewModel.move を正規化座標で呼ぶ。
private struct ControlPoint: View {
    let viewModel: MappingViewModel
    let surface: Surface
    let corner: Quad.Corner
    let canvasRect: CGRect
    let color: Color
    let spaceName: String

    /// 1ジェスチャ内で beginGesture を一度だけ呼ぶためのフラグ
    @State private var began = false

    private var isSelected: Bool {
        viewModel.selectedSurface == surface && viewModel.selectedCorner == corner
    }

    var body: some View {
        let normalized = viewModel.preset.surfaces[surface]?.quad[corner] ?? .zero
        let pos = MeshCanvasView.uiPoint(normalized, in: canvasRect)

        ZStack {
            Circle()
                .fill(color.opacity(isSelected ? 0.95 : 0.65))
                .frame(width: 20, height: 20)
            Circle()
                .stroke(Color.white, lineWidth: isSelected ? 3 : 1)
                .frame(width: 20, height: 20)
        }
        // タッチ判定を44ptに拡大(F-UI-1)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .opacity(viewModel.isEditLocked ? 0.4 : 1)
        .position(pos)
        .allowsHitTesting(!viewModel.isEditLocked)   // ロック時は操作不能(F-UI-6)
        .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(spaceName))
            .onChanged { value in
                // タッチした時点で選択を更新(InspectorViewと連動)
                viewModel.selectedSurface = surface
                viewModel.selectedCorner = corner

                // 微小移動はタップ(選択のみ)とみなし、ドラッグ開始扱いにしない
                let moved = hypot(value.translation.width, value.translation.height)
                guard began || moved >= 2 else { return }

                if !began {
                    began = true
                    viewModel.beginGesture()   // 1ジェスチャ=1アンドゥ単位
                }
                let norm = MeshCanvasView.normalized(value.location, in: canvasRect)
                viewModel.move(corner: corner, of: surface, to: norm)
            }
            .onEnded { _ in
                began = false
            }
    }
}
