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
    var isEditLocked = false             // F-UI-6

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
        self.preset = presetStore.loadLastUsed() ?? .makeDefault()
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
