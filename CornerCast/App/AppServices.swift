import Foundation

/// 依存の組み立てと共有(コンポジションルート)。
/// 外部ディスプレイシーンは環境注入(@UIApplicationDelegateAdaptor経由)が使えないため、
/// メイン/外部の両シーンがここから同一インスタンスを取得する。
@MainActor
final class AppServices {
    static let shared = AppServices()

    let presetStore: PresetStoreProtocol
    let viewModel: MappingViewModel
    let composer = FrameComposer()
    let externalDisplayManager: ExternalDisplayManager
    /// 外部制御(OSC/MIDI)。設定に応じてControlSettingsViewから起動される。
    let controlHub: ControlHub

    private init() {
        let store = PresetStore()
        self.presetStore = store
        let vm = MappingViewModel(presetStore: store)
        self.viewModel = vm
        self.externalDisplayManager = ExternalDisplayManager(viewModel: vm, composer: FrameComposer())
        self.controlHub = ControlHub(viewModel: vm)
    }
}
