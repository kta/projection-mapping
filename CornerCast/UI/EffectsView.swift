import SwiftUI

/// 出力エフェクト(F-FX-1)編集シート。
///
/// TODO(TASK UX-1 / 担当: ux agent):
/// - preset.effectSettings をスライダー4本で編集:
///   彩度 0-2 / コントラスト 0.5-1.5 / 明度 -0.5-0.5 / 色相 -180-180
/// - 各スライダーのonEditingChanged開始時に viewModel.beginGesture()(アンドゥ単位)。
/// - 「リセット」ボタンで .neutral に戻す(beginGestureを積んでから)。
/// - 値はリアルタイムに投影へ反映される(RenderParameters経由)旨をfooterに表示。
struct EffectsView: View {
    @Bindable var viewModel: MappingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Text("TODO: UX-1 EffectsView") // TODO: UX-1
    }
}
