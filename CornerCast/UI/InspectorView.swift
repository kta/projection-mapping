import SwiftUI

/// インスペクタ(F-UI-3/4/5、F-WARP-5/6)。選択中の面・頂点に対する精密操作。
///
/// TODO(TASK UI-2 / 担当: ui agent):
/// セクション構成(Form):
/// 1. 選択中の面/頂点の表示。頂点座標の数値表示+TextFieldで直接入力(F-UI-5、0-1範囲検証)。
/// 2. 微調整十字キー(F-UI-3): ↑↓←→ボタン。タップで viewModel.nudge(dx:dy:) ±1、
///    長押しでリピート(0.1秒間隔)。
/// 3. 面の明るさ/ガンマ Slider(F-WARP-6): brightness 0.25-2.0、gamma 0.25-4.0。
/// 4. 頂点リンク(F-WARP-5): preset.links を Toggle で列挙(viewModel.setLink(id:enabled:))。
/// 5. リセット(面単位/全体)+アンドゥボタン(canUndoで活性制御)+編集ロックToggle。
struct InspectorView: View {
    @Bindable var viewModel: MappingViewModel

    var body: some View {
        Text("TODO: UI-2 InspectorView") // TODO: UI-2
    }
}
