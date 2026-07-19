import Foundation
import Observation
import CoreGraphics

/// アプリ全体の状態源(single source of truth)。
/// iPad側UI(SwiftUI)と外部ディスプレイレンダラの両方がここを観測する。
/// 注意: 外部シーンへは @UIApplicationDelegateAdaptor 経由の環境注入を使わないこと
/// (クラッシュ事例あり — 調査レポート§1)。AppServices.shared 経由で渡す。
@MainActor
@Observable
final class MappingViewModel {

    // MARK: 状態

    var preset: MappingPreset {
        didSet { scheduleAutosave() }
    }

    enum OutputMode: String, CaseIterable {
        case realtime      // F-RT-1
        case bakedPlayback // F-BAKE-2
    }
    var outputMode: OutputMode = .realtime

    enum ContentSource: Equatable {
        case none
        case testPattern                 // F-UI-2
        case image(URL)
        case video(URL)
        case bakedVideo(URL)             // ベイク再生用(ワープ処理なしで再生)
    }
    var contentSource: ContentSource = .testPattern

    struct DisplayState: Equatable {
        var isConnected: Bool = false
        var resolution: CGSize = .zero
        var refreshRate: Double = 0
    }
    var displayState = DisplayState()

    var selectedSurface: Surface? = .frontWall
    var selectedCorner: Quad.Corner?
    /// 選択中の自由面(F-FREE-1)。コーナー3面の選択とは排他(UI側で切替時に相手をnilにする)。
    var selectedExtraID: UUID?
    /// 選択中のマスク(F-MASK-1)。面選択とは排他。
    var selectedMaskID: UUID?
    var isEditLocked = false             // F-UI-6
    /// 初回起動(保存済み状態なし)ならユースケース選択(F-TPL-1)を表示する
    var needsWelcome = false

    // MARK: 依存

    /// 現在アクティブな動画ソース(ExternalDisplayManagerが結線時に設定・解除する)。
    /// UIのトランスポート(TransportView)が再生制御(play/pause/seek)に使う。
    /// 再生状態の表示はUI側ローカル状態でよいため観測対象にしない。
    @ObservationIgnored weak var activeVideoSource: VideoSource?

    @ObservationIgnored private let presetStore: PresetStoreProtocol
    @ObservationIgnored private var undoStack: [MappingPreset] = []
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    private static let undoLimit = 20    // F-UI-4

    init(presetStore: PresetStoreProtocol) {
        self.presetStore = presetStore
        if let last = presetStore.loadLastUsed() {
            self.preset = last
        } else {
            self.preset = .makeDefault()
            self.needsWelcome = true     // 初回はユースケース選択から(F-TPL-1)
        }
    }

    // MARK: テンプレート(F-TPL-1)

    /// ユースケーステンプレートを適用する(現在の状態はアンドゥで戻せる)
    func apply(template: MappingPreset.ProjectTemplate) {
        pushUndo()
        preset = MappingPreset.make(template: template)
        selectedSurface = template == .freeform ? nil : .frontWall
        selectedCorner = nil
        selectedExtraID = template == .freeform ? preset.extras.first?.id : nil
        selectedMaskID = nil
        if template == .sample {
            contentSource = .testPattern
        }
        preset.updatedAt = .now
    }

    // MARK: レンダラ向けスナップショット

    /// レンダラは毎フレームこれを呼ぶ。値型なのでスレッド境界を安全に越えられる。
    func renderParameters(canvasSize: CGSize) -> RenderParameters {
        RenderParameters(canvasSize: canvasSize, preset: preset)
    }

    // MARK: 頂点操作(F-UI-1 / F-WARP-5)

    /// ドラッグ開始時に呼ぶ(1ジェスチャ=1アンドゥ単位)
    func beginGesture() {
        pushUndo()
    }

    /// 頂点を移動する。クランプと頂点リンクの解決を含む。
    func move(corner: Quad.Corner, of surface: Surface, to normalizedPoint: CGPoint) {
        guard !isEditLocked else { return }
        let p = Quad.clamped(normalizedPoint)
        preset.surfaces[surface]?.quad[corner] = p
        resolveLinks(changed: .init(surface: surface, corner: corner), to: p)
        preset.updatedAt = .now
    }

    /// 微調整(F-UI-3): 1px相当のナッジ。キャンバス解像度が未知のUI側からはpt換算せず
    /// 「出力1080p想定で1px = 1/1080」を単位とする。
    func nudge(corner: Quad.Corner, of surface: Surface, dx: Double, dy: Double) {
        guard let quad = preset.surfaces[surface]?.quad else { return }
        pushUndo()
        let unit = 1.0 / 1080.0
        let current = quad[corner]
        move(corner: corner, of: surface,
             to: CGPoint(x: current.x + dx * unit, y: current.y + dy * unit))
    }

    /// 面全体を平行移動する(F-UI-7)。baseはジェスチャ開始時のquad。
    /// 全頂点が0-1に収まるようdeltaを事前クランプし、形状を保ったまま動かす。
    /// 各頂点の適用はmove()を通すため、頂点リンクも通常どおり解決される。
    func translate(surface: Surface, by delta: CGPoint, from base: Quad) {
        guard !isEditLocked else { return }
        let clamped = Self.clampedDelta(delta, for: base)
        for c in Quad.Corner.allCases {
            let p = base[c]
            move(corner: c, of: surface, to: CGPoint(x: p.x + clamped.x, y: p.y + clamped.y))
        }
    }

    // MARK: クロップ編集(F-CROP-2/3)

    /// クロップ矩形を更新する。0-1へのクランプと最小サイズ(5%)を保証する。
    /// 面同士の重複は意図的に許容する(F-CROP-3: 境界を重ねて継ぎ目の連続感を出す用途)。
    func setCrop(_ rect: CGRect, for surface: Surface) {
        guard !isEditLocked else { return }
        preset.surfaces[surface]?.crop = Self.clampedCrop(rect)
        preset.updatedAt = .now
    }

    /// setCrop/setExtraCropで共有するクランプ規則(0-1・最小サイズ5%)
    static func clampedCrop(_ rect: CGRect) -> CGRect {
        let minSize: CGFloat = 0.05
        var r = rect
        r.size.width = min(max(r.width, minSize), 1)
        r.size.height = min(max(r.height, minSize), 1)
        r.origin.x = min(max(r.origin.x, 0), 1 - r.width)
        r.origin.y = min(max(r.origin.y, 0), 1 - r.height)
        return r
    }

    // MARK: 自由面(F-FREE-1)

    /// 自由面を追加し、選択状態にする。初期位置はキャンバス右下寄りの小矩形。
    func addExtraSurface() {
        guard !isEditLocked else { return }
        pushUndo()
        var extras = preset.extras
        let config = SurfaceConfig(
            crop: CGRect(x: 0.7, y: 0.7, width: 0.25, height: 0.25),
            quad: Quad(rect: CGRect(x: 0.7, y: 0.72, width: 0.2, height: 0.2)))
        extras.append(ExtraSurface(name: "追加面\(extras.count + 1)", config: config))
        preset.extras = extras
        selectedExtraID = extras.last?.id
        selectedSurface = nil
        selectedCorner = nil
        preset.updatedAt = .now
    }

    func removeExtraSurface(id: UUID) {
        guard !isEditLocked else { return }
        pushUndo()
        preset.extras.removeAll { $0.id == id }
        if selectedExtraID == id { selectedExtraID = nil }
        preset.updatedAt = .now
    }

    /// 自由面の頂点移動(コーナー3面のmoveに相当。リンク解決はない)
    func moveExtra(corner: Quad.Corner, id: UUID, to normalizedPoint: CGPoint) {
        guard !isEditLocked else { return }
        guard let i = preset.extras.firstIndex(where: { $0.id == id }) else { return }
        var extras = preset.extras
        extras[i].config.quad[corner] = Quad.clamped(normalizedPoint)
        preset.extras = extras
        preset.updatedAt = .now
    }

    /// 自由面の全体移動(translateの自由面版。形状保存クランプも同一規則)
    func translateExtra(id: UUID, by delta: CGPoint, from base: Quad) {
        guard !isEditLocked else { return }
        guard let i = preset.extras.firstIndex(where: { $0.id == id }) else { return }
        let clamped = Self.clampedDelta(delta, for: base)
        var extras = preset.extras
        for c in Quad.Corner.allCases {
            let p = base[c]
            extras[i].config.quad[c] = CGPoint(x: p.x + clamped.x, y: p.y + clamped.y)
        }
        preset.extras = extras
        preset.updatedAt = .now
    }

    func setExtraCrop(_ rect: CGRect, id: UUID) {
        guard !isEditLocked else { return }
        guard let i = preset.extras.firstIndex(where: { $0.id == id }) else { return }
        var extras = preset.extras
        extras[i].config.crop = Self.clampedCrop(rect)
        preset.extras = extras
        preset.updatedAt = .now
    }

    /// 自由面の設定(明るさ/ガンマ/フェザー/名前)を更新する汎用ミューテータ
    func updateExtra(id: UUID, _ mutate: (inout ExtraSurface) -> Void) {
        guard let i = preset.extras.firstIndex(where: { $0.id == id }) else { return }
        var extras = preset.extras
        mutate(&extras[i])
        preset.extras = extras
        preset.updatedAt = .now
    }

    // MARK: メッシュワープ(F-MESH-1)

    /// メッシュワープの有効/無効。有効化時は現在のquadから4×4で初期化する。
    func setMeshEnabled(_ enabled: Bool, for surface: Surface, rows: Int = 4, cols: Int = 4) {
        guard !isEditLocked, let config = preset.surfaces[surface] else { return }
        pushUndo()
        preset.surfaces[surface]?.mesh =
            enabled ? WarpMesh.fromQuad(config.quad, rows: rows, cols: cols) : nil
        preset.updatedAt = .now
    }

    /// メッシュ制御点の移動(0-1クランプ)。アンドゥはUI側のbeginGestureで積む。
    func moveMeshPoint(surface: Surface, index: Int, to p: CGPoint) {
        guard !isEditLocked, var mesh = preset.surfaces[surface]?.mesh,
              mesh.points.indices.contains(index) else { return }
        mesh.points[index] = Quad.clamped(p)
        preset.surfaces[surface]?.mesh = mesh
        preset.updatedAt = .now
    }

    /// 自由面版メッシュ有効/無効
    func setExtraMeshEnabled(_ enabled: Bool, id: UUID, rows: Int = 4, cols: Int = 4) {
        guard !isEditLocked else { return }
        pushUndo()
        updateExtra(id: id) { e in
            e.config.mesh = enabled ? WarpMesh.fromQuad(e.config.quad, rows: rows, cols: cols) : nil
        }
    }

    /// 自由面版メッシュ制御点の移動
    func moveExtraMeshPoint(id: UUID, index: Int, to p: CGPoint) {
        guard !isEditLocked else { return }
        updateExtra(id: id) { e in
            guard var mesh = e.config.mesh, mesh.points.indices.contains(index) else { return }
            mesh.points[index] = Quad.clamped(p)
            e.config.mesh = mesh
        }
    }

    // MARK: 出力マスク(F-MASK-1)

    func addMask() {
        guard !isEditLocked else { return }
        pushUndo()
        var masks = preset.maskShapes
        masks.append(MaskShape(name: "マスク\(masks.count + 1)",
                               quad: Quad(rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))))
        preset.maskShapes = masks
        selectedMaskID = masks.last?.id
        selectedSurface = nil
        selectedCorner = nil
        selectedExtraID = nil
        preset.updatedAt = .now
    }

    func removeMask(id: UUID) {
        guard !isEditLocked else { return }
        pushUndo()
        preset.maskShapes.removeAll { $0.id == id }
        if selectedMaskID == id { selectedMaskID = nil }
        preset.updatedAt = .now
    }

    func moveMaskCorner(id: UUID, corner: Quad.Corner, to p: CGPoint) {
        guard !isEditLocked else { return }
        guard let i = preset.maskShapes.firstIndex(where: { $0.id == id }) else { return }
        var masks = preset.maskShapes
        masks[i].quad[corner] = Quad.clamped(p)
        preset.maskShapes = masks
        preset.updatedAt = .now
    }

    func translateMask(id: UUID, by delta: CGPoint, from base: Quad) {
        guard !isEditLocked else { return }
        guard let i = preset.maskShapes.firstIndex(where: { $0.id == id }) else { return }
        let clamped = Self.clampedDelta(delta, for: base)
        var masks = preset.maskShapes
        for c in Quad.Corner.allCases {
            let p = base[c]
            masks[i].quad[c] = CGPoint(x: p.x + clamped.x, y: p.y + clamped.y)
        }
        preset.maskShapes = masks
        preset.updatedAt = .now
    }

    /// 全頂点が0-1に収まるようdeltaをクランプ(translate/translateExtra共通)
    static func clampedDelta(_ delta: CGPoint, for base: Quad) -> CGPoint {
        let corners = Quad.Corner.allCases.map { base[$0] }
        guard let minX = corners.map(\.x).min(), let maxX = corners.map(\.x).max(),
              let minY = corners.map(\.y).min(), let maxY = corners.map(\.y).max() else {
            return .zero
        }
        return CGPoint(x: min(max(delta.x, -minX), 1 - maxX),
                       y: min(max(delta.y, -minY), 1 - maxY))
    }

    private func resolveLinks(changed ref: CornerLink.CornerRef, to p: CGPoint) {
        for link in preset.links where link.enabled {
            if link.a == ref {
                preset.surfaces[link.b.surface]?.quad[link.b.corner] = p
            } else if link.b == ref {
                preset.surfaces[link.a.surface]?.quad[link.a.corner] = p
            }
        }
    }

    func setLink(id: UUID, enabled: Bool) {
        guard let i = preset.links.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        preset.links[i].enabled = enabled
        if enabled {
            // リンク有効化時はa側の現在位置にb側を吸着させる
            let link = preset.links[i]
            if let p = preset.surfaces[link.a.surface]?.quad[link.a.corner] {
                preset.surfaces[link.b.surface]?.quad[link.b.corner] = p
            }
        }
    }

    // MARK: リセット / アンドゥ(F-UI-4)

    func resetSurface(_ surface: Surface) {
        pushUndo()
        if let def = MappingPreset.makeDefault().surfaces[surface] {
            preset.surfaces[surface] = def
        }
    }

    func resetAll() {
        pushUndo()
        let def = MappingPreset.makeDefault()
        preset.surfaces = def.surfaces
        preset.links = def.links
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        preset = last
    }

    var canUndo: Bool { !undoStack.isEmpty }

    private func pushUndo() {
        undoStack.append(preset)
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
    }

    // MARK: 永続化(F-PRESET-2: 自動保存)

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))   // ドラッグ中の連続保存を抑制
            guard let self, !Task.isCancelled else { return }
            self.presetStore.saveLastUsed(self.preset)
        }
    }
}
