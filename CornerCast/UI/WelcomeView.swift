import SwiftUI

/// ユースケース選択(F-TPL-1)。初回起動時(viewModel.needsWelcome)と
/// ツールバー「新規」から表示する。
///
/// TODO(TASK UX-1 / 担当: ux agent):
/// - 3枚のカード(MappingPreset.ProjectTemplate.allCases): アイコン(systemImage)+
///   displayName + caption。タップで viewModel.apply(template:) → dismiss。
/// - デザイン: 黒基調(投影アプリらしく)、カードは大きめ・角丸・押下スケール。
///   iPad横向きで3枚横並び、縦/コンパクトで縦積み(ViewThatFits or Grid)。
/// - 初回起動時はスキップ不可にしない(閉じるボタンあり: その場合は現在のプリセットのまま)。
struct WelcomeView: View {
    @Bindable var viewModel: MappingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Text("TODO: UX-1 WelcomeView") // TODO: UX-1
    }
}
