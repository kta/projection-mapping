import SwiftUI

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

    var body: some View {
        GeometryReader { geo in
            let canvasRect = Self.letterboxRect(in: geo.size)
            ZStack {
                // 背景(F-OUT-4のプレビュー相当。初版はワイヤーフレームのみ)
                Color.black
                Rectangle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    .frame(width: canvasRect.width, height: canvasRect.height)
                    .position(x: canvasRect.midX, y: canvasRect.midY)

                // 3面ワイヤーフレーム(drawOrder順に下から描画)
                ForEach(Surface.drawOrder, id: \.self) { s in
                    if let quad = viewModel.preset.surfaces[s]?.quad {
                        let selected = viewModel.selectedSurface == s
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
        }
        .background(Color.black)
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
