import SwiftUI

/// メイン編集画面(要件§5の画面仕様)。
///
/// TODO(TASK UI-1 / 担当: ui agent):
/// レイアウト:
///   NavigationStack {
///     HStack { MeshCanvasView(≒左7割) / InspectorView(右3割・固定幅280pt) }
///     .toolbar { コンテンツ選択 / モード切替(RT・ベイク) / テストパターン /
///                プリセット / 出力状態インジケータ(displayState) }
///     下部に TransportView
///   }
/// - コンテンツ選択はContentPickerView(UI-2)をsheet表示。
/// - プリセットはPresetListView(UI-2)をsheet表示。
/// - 出力状態: 緑●=接続中(解像度表示)、灰●=未接続(F-OUT-3)。
struct EditorView: View {
    @Bindable var viewModel: MappingViewModel

    var body: some View {
        Text("TODO: UI-1 EditorView") // TODO: UI-1
    }
}
