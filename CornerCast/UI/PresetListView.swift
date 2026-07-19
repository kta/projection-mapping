import SwiftUI

/// プリセット管理画面(F-PRESET-1/3)。
///
/// TODO(TASK UI-2 / 担当: ui agent):
/// - List: PresetStore.listPresets()。行タップで読み込み(viewModel.preset差し替え)、
///   スワイプ削除、名前変更(TextField)。
/// - 「現在の状態を保存」ボタン(名前入力ダイアログ)。
/// - JSON書き出し/読み込み(F-PRESET-3): ShareLink(書き出し)+fileImporter(読み込み)。
struct PresetListView: View {
    @Bindable var viewModel: MappingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Text("TODO: UI-2 PresetListView") // TODO: UI-2
    }
}
