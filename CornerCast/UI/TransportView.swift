import SwiftUI

/// トランスポートバー(F-SRC-4)+ベイク操作(F-BAKE系)。
///
/// TODO(TASK UI-2 / 担当: ui agent):
/// - 再生/一時停止・シークSlider・ループToggle・音量Slider。
///   VideoSourceの制御はViewModel経由にしたいが、初版はAppServices.sharedの
///   現在のFrameSourceを直接叩く形でもよい(TODOコメントを残すこと)。
/// - ベイク: 「この設定で書き出し」ボタン → 確認ダイアログ(解像度選択: 1080p/4K)
///   → BakeExporter.export を Task で実行、ProgressViewをオーバーレイ表示、キャンセル可。
/// - 書き出し完了後は outputMode を .bakedPlayback に切替提案するアラートを出す。
/// - ベイクが陳腐化している場合(BakeStore.isStale)は「再書き出しが必要」バッジ表示(F-BAKE-3)。
struct TransportView: View {
    @Bindable var viewModel: MappingViewModel

    var body: some View {
        Text("TODO: UI-2 TransportView") // TODO: UI-2
    }
}
