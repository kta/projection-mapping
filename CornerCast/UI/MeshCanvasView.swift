import SwiftUI
import Foundation

/// メッシュ編集キャンバス(F-UI-1 / F-MESH-1 / F-MASK-1)。
/// 3面のワイヤーフレーム+12個のコントロールポイントを描画し、ドラッグで頂点を動かす。
/// さらにメッシュワープ有効面のメッシュ点編集、出力マスクの編集を行う。
///
/// 実装方針(TASK UI-1 / PRO-A):
/// - GeometryReaderで自サイズを取得し、出力アスペクト(16:9)のレターボックス矩形を中央に置く。
/// - 各Surfaceのquadを Path で描画(選択中の面はハイライト)。識別色はTestPatternと同じ
///   (左壁=シアン/正面壁=マゼンタ/床=イエロー)。
/// - メッシュ有効面はquadの代わりにメッシュ外周を描き、4隅ハンドルの代わりに
///   rows×colsのメッシュ点(見た目12pt・タッチ44pt)を出す(選択中の面のみ)。
/// - 出力マスクは赤ワイヤーフレーム+塗り(0.15)で全レイヤーの最上位に描く。
/// - コントロールポイント: 見た目20pt・タッチ判定44pt(44×44のframe+contentShape)。
/// - 座標変換は CoordinateMapper 経由のみ(手計算・Y反転の直書き禁止)。
///
/// bodyの型チェック時間爆発を避けるため、レイヤーごとに関数へ分割している
/// (PresetListViewと同じ方針。安易に統合しないこと)。
struct MeshCanvasView: View {
    @Bindable var viewModel: MappingViewModel

    /// ドラッグ判定に使う座標空間名。
    private static let space = "CornerCast.canvas"
    /// 合成プレビュー(F-OUT-4)。EditorPreviewRendererがデバウンス付きで更新する。
    @State private var previewImage: UIImage?
    /// 面全体ドラッグ(F-UI-7)のジェスチャ開始時quad
    @State private var surfaceDragBase: [Surface: Quad] = [:]
    /// 自由面(F-FREE-1)の全体ドラッグ開始時quad
    @State private var extraDragBase: [UUID: Quad] = [:]
    /// マスク(F-MASK-1)の全体ドラッグ開始時quad
    @State private var maskDragBase: [UUID: Quad] = [:]

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

                // コーナー3面(F-WARP): ワイヤーフレーム → 4隅ハンドル → メッシュ点
                surfaceLayer(canvasRect: canvasRect)
                cornerHandles(canvasRect: canvasRect)
                surfaceMeshHandles(canvasRect: canvasRect)

                // 自由面(F-FREE-1): ワイヤーフレーム → 4隅ハンドル → メッシュ点
                extraLayer(canvasRect: canvasRect)
                extraHandles(canvasRect: canvasRect)
                extraMeshHandles(canvasRect: canvasRect)

                // 出力マスク(F-MASK-1): 常に最上位
                maskLayer(canvasRect: canvasRect)
                maskHandles(canvasRect: canvasRect)
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

    // MARK: - レイヤー(型チェック分割のため関数化)

    /// コーナー3面のワイヤーフレーム(drawOrder順に下から描画)
    @ViewBuilder private func surfaceLayer(canvasRect: CGRect) -> some View {
        ForEach(Surface.drawOrder, id: \.self) { s in
            surfaceWireframe(s, canvasRect: canvasRect)
        }
    }

    /// 4隅ハンドル。メッシュ有効面(mesh非nil)は隠す。
    @ViewBuilder private func cornerHandles(canvasRect: CGRect) -> some View {
        ForEach(Surface.allCases) { s in
            if viewModel.preset.surfaces[s]?.mesh == nil {
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
    }

    /// メッシュ点。選択中かつmesh有効な面のみ表示(非選択面はごちゃつき防止で外周のみ)。
    @ViewBuilder private func surfaceMeshHandles(canvasRect: CGRect) -> some View {
        ForEach(Surface.allCases) { s in
            if viewModel.selectedSurface == s, let mesh = viewModel.preset.surfaces[s]?.mesh {
                ForEach(Array(mesh.points.indices), id: \.self) { i in
                    MeshControlPoint(
                        viewModel: viewModel,
                        surface: s,
                        extraID: nil,
                        index: i,
                        canvasRect: canvasRect,
                        color: color(for: s),
                        spaceName: Self.space
                    )
                }
            }
        }
    }

    /// 自由面のワイヤーフレーム(mesh有無で分岐)
    @ViewBuilder private func extraLayer(canvasRect: CGRect) -> some View {
        ForEach(viewModel.preset.extras) { extra in
            extraWireframe(extra, canvasRect: canvasRect)
        }
    }

    /// 自由面の4隅ハンドル。メッシュ有効面は隠す。
    @ViewBuilder private func extraHandles(canvasRect: CGRect) -> some View {
        ForEach(viewModel.preset.extras) { extra in
            if extra.config.mesh == nil {
                ForEach(Quad.Corner.allCases) { c in
                    ExtraControlPoint(
                        viewModel: viewModel,
                        extraID: extra.id,
                        corner: c,
                        canvasRect: canvasRect,
                        spaceName: Self.space
                    )
                }
            }
        }
    }

    /// 自由面のメッシュ点(選択中のみ)
    @ViewBuilder private func extraMeshHandles(canvasRect: CGRect) -> some View {
        ForEach(viewModel.preset.extras) { extra in
            if viewModel.selectedExtraID == extra.id, let mesh = extra.config.mesh {
                ForEach(Array(mesh.points.indices), id: \.self) { i in
                    MeshControlPoint(
                        viewModel: viewModel,
                        surface: nil,
                        extraID: extra.id,
                        index: i,
                        canvasRect: canvasRect,
                        color: .green,
                        spaceName: Self.space
                    )
                }
            }
        }
    }

    /// 出力マスクのワイヤーフレーム+塗り(F-MASK-1)
    @ViewBuilder private func maskLayer(canvasRect: CGRect) -> some View {
        ForEach(viewModel.preset.maskShapes) { mask in
            maskWireframe(mask, canvasRect: canvasRect)
        }
    }

    /// マスクの4隅ハンドル
    @ViewBuilder private func maskHandles(canvasRect: CGRect) -> some View {
        ForEach(viewModel.preset.maskShapes) { mask in
            ForEach(Quad.Corner.allCases) { c in
                MaskControlPoint(
                    viewModel: viewModel,
                    maskID: mask.id,
                    corner: c,
                    canvasRect: canvasRect,
                    spaceName: Self.space
                )
            }
        }
    }

    // MARK: - 面ワイヤーフレーム(mesh有無で分岐)

    /// コーナー1面ぶんのワイヤーフレーム+全体ドラッグ(通常)/選択(メッシュ)。
    @ViewBuilder private func surfaceWireframe(_ s: Surface, canvasRect: CGRect) -> some View {
        if let config = viewModel.preset.surfaces[s] {
            let selected = viewModel.selectedSurface == s
            if let mesh = config.mesh {
                // メッシュ有効: 外周を描く。メッシュにはtranslate APIが無いため
                // 面全体ドラッグは行わず、外周タップで選択のみ受け付ける。
                meshOutlinePath(mesh, in: canvasRect)
                    .fill(Color.white.opacity(0.001))
                    .onTapGesture { selectSurface(s) }
                    .allowsHitTesting(!viewModel.isEditLocked)
                meshOutlinePath(mesh, in: canvasRect)
                    .stroke(color(for: s),
                            style: StrokeStyle(lineWidth: selected ? 3 : 1.5, lineJoin: .round))
                    .opacity(viewModel.isEditLocked ? 0.5 : 1)
                Text(s.displayName)
                    .font(.caption2)
                    .foregroundStyle(color(for: s))
                    .position(centroid(config.quad, in: canvasRect))
            } else {
                let quad = config.quad
                // 面の内側をドラッグすると面全体を平行移動(F-UI-7)。
                quadPath(quad, in: canvasRect)
                    .fill(Color.white.opacity(0.001))
                    .gesture(surfaceDragGesture(s, canvasRect: canvasRect))
                    .allowsHitTesting(!viewModel.isEditLocked)
                quadPath(quad, in: canvasRect)
                    .stroke(color(for: s),
                            style: StrokeStyle(lineWidth: selected ? 3 : 1.5, lineJoin: .round))
                    .opacity(viewModel.isEditLocked ? 0.5 : 1)
                Text(s.displayName)
                    .font(.caption2)
                    .foregroundStyle(color(for: s))
                    .position(centroid(quad, in: canvasRect))
            }
        }
    }

    /// 自由面1枚ぶんのワイヤーフレーム+全体ドラッグ(通常)/選択(メッシュ)。
    @ViewBuilder private func extraWireframe(_ extra: ExtraSurface, canvasRect: CGRect) -> some View {
        let selected = viewModel.selectedExtraID == extra.id
        if let mesh = extra.config.mesh {
            meshOutlinePath(mesh, in: canvasRect)
                .fill(Color.white.opacity(0.001))
                .onTapGesture { selectExtra(extra.id) }
                .allowsHitTesting(!viewModel.isEditLocked)
            meshOutlinePath(mesh, in: canvasRect)
                .stroke(Color.green,
                        style: StrokeStyle(lineWidth: selected ? 3 : 1.5, lineJoin: .round))
                .opacity(viewModel.isEditLocked ? 0.5 : 1)
            Text(extra.name)
                .font(.caption2)
                .foregroundStyle(Color.green)
                .position(centroid(extra.config.quad, in: canvasRect))
        } else {
            let quad = extra.config.quad
            quadPath(quad, in: canvasRect)
                .fill(Color.white.opacity(0.001))
                .gesture(extraBodyGesture(extra.id, canvasRect: canvasRect))
                .allowsHitTesting(!viewModel.isEditLocked)
            quadPath(quad, in: canvasRect)
                .stroke(Color.green,
                        style: StrokeStyle(lineWidth: selected ? 3 : 1.5, lineJoin: .round))
                .opacity(viewModel.isEditLocked ? 0.5 : 1)
            Text(extra.name)
                .font(.caption2)
                .foregroundStyle(Color.green)
                .position(centroid(quad, in: canvasRect))
        }
    }

    /// マスク1枚ぶんのワイヤーフレーム+塗り+全体ドラッグ(F-MASK-1)
    @ViewBuilder private func maskWireframe(_ mask: MaskShape, canvasRect: CGRect) -> some View {
        let selected = viewModel.selectedMaskID == mask.id
        quadPath(mask.quad, in: canvasRect)
            .fill(Color.red.opacity(0.15))
            .gesture(maskBodyGesture(mask.id, canvasRect: canvasRect))
            .allowsHitTesting(!viewModel.isEditLocked)
        quadPath(mask.quad, in: canvasRect)
            .stroke(Color.red,
                    style: StrokeStyle(lineWidth: selected ? 3 : 1.5, lineJoin: .round))
            .opacity(viewModel.isEditLocked ? 0.5 : 1)
        Text(mask.name)
            .font(.caption2)
            .foregroundStyle(Color.red)
            .position(centroid(mask.quad, in: canvasRect))
    }

    // MARK: - ジェスチャ

    private func extraBodyGesture(_ id: UUID, canvasRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                selectExtra(id)
                if extraDragBase[id] == nil {
                    viewModel.beginGesture()
                    extraDragBase[id] = viewModel.preset.extras.first { $0.id == id }?.config.quad
                }
                guard let base = extraDragBase[id], canvasRect.width > 0 else { return }
                let delta = CGPoint(x: value.translation.width / canvasRect.width,
                                    y: value.translation.height / canvasRect.height)
                viewModel.translateExtra(id: id, by: delta, from: base)
            }
            .onEnded { _ in extraDragBase[id] = nil }
    }

    /// マスク全体の平行移動ジェスチャ(F-MASK-1)。extraBodyGestureに準拠。
    private func maskBodyGesture(_ id: UUID, canvasRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                selectMask(id)
                if maskDragBase[id] == nil {
                    viewModel.beginGesture()
                    maskDragBase[id] = viewModel.preset.maskShapes.first { $0.id == id }?.quad
                }
                guard let base = maskDragBase[id], canvasRect.width > 0 else { return }
                let delta = CGPoint(x: value.translation.width / canvasRect.width,
                                    y: value.translation.height / canvasRect.height)
                viewModel.translateMask(id: id, by: delta, from: base)
            }
            .onEnded { _ in maskDragBase[id] = nil }
    }

    /// 面全体の平行移動ジェスチャ(F-UI-7)
    private func surfaceDragGesture(_ s: Surface, canvasRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                viewModel.selectedSurface = s
                viewModel.selectedExtraID = nil
                viewModel.selectedMaskID = nil
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

    // MARK: - 選択ヘルパー(選択は面/自由面/マスクで排他)

    private func selectSurface(_ s: Surface) {
        viewModel.selectedSurface = s
        viewModel.selectedExtraID = nil
        viewModel.selectedMaskID = nil
    }

    private func selectExtra(_ id: UUID) {
        viewModel.selectedExtraID = id
        viewModel.selectedSurface = nil
        viewModel.selectedCorner = nil
        viewModel.selectedMaskID = nil
    }

    private func selectMask(_ id: UUID) {
        viewModel.selectedMaskID = id
        viewModel.selectedSurface = nil
        viewModel.selectedCorner = nil
        viewModel.selectedExtraID = nil
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

    /// メッシュ外周のPath。上辺(row0を左→右)→右列(上→下)→下辺(右→左)→左列(下→上)。
    private func meshOutlinePath(_ mesh: WarpMesh, in rect: CGRect) -> Path {
        var path = Path()
        guard mesh.rows >= 2, mesh.cols >= 2,
              mesh.points.count == mesh.rows * mesh.cols else { return path }
        var normPts: [CGPoint] = []
        // 上辺(row 0、col 0..cols-1)
        for c in 0..<mesh.cols { normPts.append(mesh.point(row: 0, col: c)) }
        // 右列(col cols-1、row 1..rows-1)
        for r in 1..<mesh.rows { normPts.append(mesh.point(row: r, col: mesh.cols - 1)) }
        // 下辺(row rows-1、col cols-2..0 逆順)
        for c in stride(from: mesh.cols - 2, through: 0, by: -1) {
            normPts.append(mesh.point(row: mesh.rows - 1, col: c))
        }
        // 左列(col 0、row rows-2..1 逆順)
        for r in stride(from: mesh.rows - 2, through: 1, by: -1) {
            normPts.append(mesh.point(row: r, col: 0))
        }
        let uiPts = normPts.map { Self.uiPoint($0, in: rect) }
        guard let first = uiPts.first else { return path }
        path.move(to: first)
        for p in uiPts.dropFirst() { path.addLine(to: p) }
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
                // タッチした時点で選択を更新(InspectorViewと連動)。自由面・マスクの選択は解除。
                viewModel.selectedSurface = surface
                viewModel.selectedCorner = corner
                viewModel.selectedExtraID = nil
                viewModel.selectedMaskID = nil

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

// MARK: - 自由面のコントロールポイント(1頂点)

/// 自由面(F-FREE-1)用のコントロールポイント。緑固定・リンク解決なし。
private struct ExtraControlPoint: View {
    let viewModel: MappingViewModel
    let extraID: UUID
    let corner: Quad.Corner
    let canvasRect: CGRect
    let spaceName: String

    @State private var began = false

    private var isSelected: Bool { viewModel.selectedExtraID == extraID }

    var body: some View {
        let normalized = viewModel.preset.extras
            .first { $0.id == extraID }?.config.quad[corner] ?? .zero
        let pos = MeshCanvasView.uiPoint(normalized, in: canvasRect)

        ZStack {
            Circle()
                .fill(Color.green.opacity(isSelected ? 0.95 : 0.65))
                .frame(width: 20, height: 20)
            Circle()
                .stroke(Color.white, lineWidth: isSelected ? 3 : 1)
                .frame(width: 20, height: 20)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .opacity(viewModel.isEditLocked ? 0.4 : 1)
        .position(pos)
        .allowsHitTesting(!viewModel.isEditLocked)
        .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(spaceName))
            .onChanged { value in
                viewModel.selectedExtraID = extraID
                viewModel.selectedSurface = nil
                viewModel.selectedCorner = nil
                viewModel.selectedMaskID = nil

                let moved = hypot(value.translation.width, value.translation.height)
                guard began || moved >= 2 else { return }
                if !began {
                    began = true
                    viewModel.beginGesture()
                }
                let norm = MeshCanvasView.normalized(value.location, in: canvasRect)
                viewModel.moveExtra(corner: corner, id: extraID, to: norm)
            }
            .onEnded { _ in began = false }
    }
}

// MARK: - メッシュ制御点(1点)

/// メッシュワープ(F-MESH-1)の制御点。見た目12pt・タッチ44pt。
/// コーナー面(surface非nil)と自由面(extraID非nil)の両方を扱う。
private struct MeshControlPoint: View {
    let viewModel: MappingViewModel
    /// コーナー面ならその種別。自由面のときnil。
    let surface: Surface?
    /// 自由面ID。コーナー面のときnil。
    let extraID: UUID?
    let index: Int
    let canvasRect: CGRect
    let color: Color
    let spaceName: String

    @State private var began = false

    /// 対象メッシュ点の正規化座標(範囲外・mesh無効時は.zero)
    private var normalizedPoint: CGPoint {
        if let s = surface {
            if let pts = viewModel.preset.surfaces[s]?.mesh?.points, pts.indices.contains(index) {
                return pts[index]
            }
        } else if let id = extraID {
            if let pts = viewModel.preset.extras.first(where: { $0.id == id })?.config.mesh?.points,
               pts.indices.contains(index) {
                return pts[index]
            }
        }
        return .zero
    }

    var body: some View {
        let pos = MeshCanvasView.uiPoint(normalizedPoint, in: canvasRect)

        ZStack {
            Circle()
                .fill(color.opacity(0.75))
                .frame(width: 12, height: 12)
            Circle()
                .stroke(Color.white, lineWidth: 1)
                .frame(width: 12, height: 12)
        }
        // タッチ判定を44ptに拡大(見た目は12pt)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .opacity(viewModel.isEditLocked ? 0.4 : 1)
        .position(pos)
        .allowsHitTesting(!viewModel.isEditLocked)
        .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(spaceName))
            .onChanged { value in
                // 選択維持(面/自由面の別を保つ)。頂点選択・マスク選択は解除。
                if let s = surface {
                    viewModel.selectedSurface = s
                    viewModel.selectedExtraID = nil
                } else {
                    viewModel.selectedExtraID = extraID
                    viewModel.selectedSurface = nil
                }
                viewModel.selectedCorner = nil
                viewModel.selectedMaskID = nil

                let moved = hypot(value.translation.width, value.translation.height)
                guard began || moved >= 2 else { return }
                if !began {
                    began = true
                    viewModel.beginGesture()   // 1ジェスチャ=1アンドゥ単位
                }
                let norm = MeshCanvasView.normalized(value.location, in: canvasRect)
                if let s = surface {
                    viewModel.moveMeshPoint(surface: s, index: index, to: norm)
                } else if let id = extraID {
                    viewModel.moveExtraMeshPoint(id: id, index: index, to: norm)
                }
            }
            .onEnded { _ in began = false }
    }
}

// MARK: - マスクのコントロールポイント(1頂点)

/// 出力マスク(F-MASK-1)用のコントロールポイント。赤固定。
private struct MaskControlPoint: View {
    let viewModel: MappingViewModel
    let maskID: UUID
    let corner: Quad.Corner
    let canvasRect: CGRect
    let spaceName: String

    @State private var began = false

    private var isSelected: Bool { viewModel.selectedMaskID == maskID }

    var body: some View {
        let normalized = viewModel.preset.maskShapes
            .first { $0.id == maskID }?.quad[corner] ?? .zero
        let pos = MeshCanvasView.uiPoint(normalized, in: canvasRect)

        ZStack {
            Circle()
                .fill(Color.red.opacity(isSelected ? 0.95 : 0.65))
                .frame(width: 20, height: 20)
            Circle()
                .stroke(Color.white, lineWidth: isSelected ? 3 : 1)
                .frame(width: 20, height: 20)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .opacity(viewModel.isEditLocked ? 0.4 : 1)
        .position(pos)
        .allowsHitTesting(!viewModel.isEditLocked)
        .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(spaceName))
            .onChanged { value in
                viewModel.selectedMaskID = maskID
                viewModel.selectedSurface = nil
                viewModel.selectedCorner = nil
                viewModel.selectedExtraID = nil

                let moved = hypot(value.translation.width, value.translation.height)
                guard began || moved >= 2 else { return }
                if !began {
                    began = true
                    viewModel.beginGesture()
                }
                let norm = MeshCanvasView.normalized(value.location, in: canvasRect)
                viewModel.moveMaskCorner(id: maskID, corner: corner, to: norm)
            }
            .onEnded { _ in began = false }
    }
}
