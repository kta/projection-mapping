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
    var outputMode: OutputMode = .realtime {
        didSet { if outputMode != oldValue { playback?.reconcile() } }
    }

    enum ContentSource: Equatable {
        case none
        case testPattern                 // F-UI-2
        case image(URL)
        case video(URL)
        case bakedVideo(URL)             // ベイク再生用(ワープ処理なしで再生)

        /// この素材を再生できる出力モード。両者の整合はここが唯一の定義。
        var requiredOutputMode: OutputMode {
            if case .bakedVideo = self { return .bakedPlayback }
            return .realtime
        }
    }
    var contentSource: ContentSource = .testPattern {
        didSet { if contentSource != oldValue { playback?.reconcile() } }
    }

    /// コンテンツを選ぶ唯一の入口(F-SRC-1/2 / F-BAKE-2)。
    ///
    /// **contentSource だけを書き換えてはいけない。** 出力モードと素材の種別を
    /// 整合させる主体が居ないと、ベイク再生モードのまま別の動画を選んだときに
    /// 前の映像が投影され続ける(切り替わらないので、ユーザーは操作が効いていないと感じる)。
    /// 逆にベイク済み動画をリアルタイムモードで選ぶと、合成済みの絵をもう一度ワープしてしまう。
    func selectContent(_ source: ContentSource) {
        outputMode = source.requiredOutputMode
        contentSource = source
    }

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

    /// 再生パイプラインの所有者(AppServicesが生成直後に設定する)。
    /// 外部ディスプレイの接続有無に関わらず常に生きている — トランスポート(TransportView)も
    /// 外部制御(ControlHub)も、再生操作はすべてここへ委譲する。
    /// 参照自体は差し替わらないので観測対象にしない(中身の状態は PlaybackCoordinator 側が @Observable)。
    @ObservationIgnored var playback: PlaybackCoordinator?

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
            selectContent(.testPattern)
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

    /// 微調整(F-UI-3): 出力1px相当のナッジ。
    ///
    /// 正規化座標の x は「幅に対する比」、y は「高さに対する比」なので、
    /// 単位は軸ごとに違う。以前は縦横とも 1/1080 だったため、横方向は
    /// 1080p で 1.78px、4K で 3.56px 動いており「±1px」の表示と食い違っていた。
    func nudge(corner: Quad.Corner, of surface: Surface, dx: Double, dy: Double) {
        guard let quad = preset.surfaces[surface]?.quad else { return }
        pushUndo()
        let unit = nudgeUnit
        let current = quad[corner]
        move(corner: corner, of: surface,
             to: CGPoint(x: current.x + dx * unit.width, y: current.y + dy * unit.height))
    }

    /// 出力1pxに相当する正規化量(軸別)。外部ディスプレイ未接続時は1080pを仮定する。
    var nudgeUnit: CGSize {
        let r = displayState.resolution
        let w = (r.width.isFinite && r.width >= 1) ? r.width : 1920
        let h = (r.height.isFinite && r.height >= 1) ? r.height : 1080
        return CGSize(width: 1.0 / w, height: 1.0 / h)
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

    /// クロップだけを既定へ戻す(F-CROP-1)。
    /// 12点の調整は保ったまま、切り出し領域だけをやり直したいことがある。
    /// resetAll は quad まで戻してしまうため、別の入口が要る。
    func resetCrops() {
        guard !isEditLocked else { return }
        pushUndo()
        let def = MappingPreset.makeDefault()
        for s in Surface.allCases {
            if let crop = def.surfaces[s]?.crop {
                preset.surfaces[s]?.crop = crop
            }
        }
        preset.updatedAt = .now
    }

    /// setCrop/setExtraCropで共有するクランプ規則(0-1・最小サイズ5%)。
    /// 実体は SurfaceConfig 側に置き、デコード時の sanitize と同一規則を共有する。
    static func clampedCrop(_ rect: CGRect) -> CGRect {
        SurfaceConfig.clampedCrop(rect)
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
        guard !isEditLocked else { return }
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

    /// 頂点リンク(F-WARP-5)の伝播。
    ///
    /// **推移閉包を取ること。** 部屋のコーナーで左壁・正面壁・床が交わる点は
    /// 3頂点で表され、既定プリセットでは leftWall.bottomRight—frontWall.bottomLeft と
    /// frontWall.bottomLeft—floor.topLeft の2本の鎖でつながる。
    /// 1ホップしか回さないと、鎖の端(leftWall側)を動かしたときに floor が置き去りになり、
    /// 「常に同一座標に保つ」という CornerLink の宣言が破れる。しかも編集順に依存するため、
    /// リンクを信じて作業しているユーザーには気づけないまま継ぎ目が割れていく。
    private func resolveLinks(changed ref: CornerLink.CornerRef, to p: CGPoint) {
        var visited: Set<CornerLink.CornerRef> = [ref]
        var frontier: [CornerLink.CornerRef] = [ref]

        while let current = frontier.popLast() {
            for link in preset.links where link.enabled {
                let neighbor: CornerLink.CornerRef?
                if link.a == current {
                    neighbor = link.b
                } else if link.b == current {
                    neighbor = link.a
                } else {
                    neighbor = nil
                }
                guard let next = neighbor, !visited.contains(next) else { continue }
                visited.insert(next)
                frontier.append(next)
                preset.surfaces[next.surface]?.quad[next.corner] = p
            }
        }
    }

    func setLink(id: UUID, enabled: Bool) {
        guard !isEditLocked else { return }
        guard let i = preset.links.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        preset.links[i].enabled = enabled
        if enabled {
            // リンク有効化時はa側の現在位置へ、連結する頂点すべてを吸着させる
            let link = preset.links[i]
            if let p = preset.surfaces[link.a.surface]?.quad[link.a.corner] {
                resolveLinks(changed: link.a, to: p)
            }
        }
        preset.updatedAt = .now
    }

    // MARK: リセット / アンドゥ(F-UI-4)

    // 編集ロック(F-UI-6)は本番投影中の誤操作を防ぐためのもの。
    // リセットは最も破壊的な操作なので、ロックを最優先で尊重する。
    func resetSurface(_ surface: Surface) {
        guard !isEditLocked else { return }
        pushUndo()
        if let def = MappingPreset.makeDefault().surfaces[surface] {
            preset.surfaces[surface] = def
        }
        preset.updatedAt = .now
    }

    func resetAll() {
        guard !isEditLocked else { return }
        pushUndo()
        let def = MappingPreset.makeDefault()
        preset.surfaces = def.surfaces
        preset.links = def.links
        preset.updatedAt = .now
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
