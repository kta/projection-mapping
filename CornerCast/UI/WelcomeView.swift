import SwiftUI

/// ユースケース選択(F-TPL-1)。初回起動時(viewModel.needsWelcome)と
/// ツールバー「新規」から表示する。
///
/// デザイン(v1.6): 生成りがかった温かい白のフルスクリーン。タイトル + サブタイトルの下に
/// ProjectTemplate.allCases の3枚カード(白カード+やわらかい影)を並べる
/// (横幅が広ければ横並び、狭ければ縦積み)。
/// カードタップで軽い押下スケール → apply(template:) → dismiss。
/// 右上「閉じる」で現在のプリセットのまま抜けられる(スキップ可能)。
struct WelcomeView: View {
    @Bindable var viewModel: MappingViewModel
    @Environment(\.dismiss) private var dismiss

    /// 「3面コーナー」選択後はカードの代わりに、かんたんセットアップ(F-EASY-1)を
    /// この画面内でそのまま表示する(ネスト表示にせず入れ替える — 閉じる動線が一本になる)。
    @State private var startedSimpleSetup = false

    var body: some View {
        ZStack {
            Color.ccBackground.ignoresSafeArea()
            if startedSimpleSetup {
                SimpleSetupView(viewModel: viewModel) {
                    dismiss()
                }
            } else {
                content
                closeButton
            }
        }
        .preferredColorScheme(.light)
        .tint(Color.ccAccent)
    }

    // MARK: タイトル + カード群

    private var content: some View {
        VStack(spacing: 40) {
            header
            cards
        }
        .padding(40)
        .frame(maxWidth: 1000)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text("CornerCast")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text("どこから始めますか?")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    /// 横幅が足りれば3枚横並び、足りなければ縦積み(ViewThatFits)。
    private var cards: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { cardList }
            VStack(spacing: 20) { cardList }
        }
    }

    @ViewBuilder private var cardList: some View {
        ForEach(MappingPreset.ProjectTemplate.allCases) { template in
            TemplateCard(template: template) {
                viewModel.apply(template: template)
                if template == .cornerCockpit {
                    // 初心者の主用途はガイドで完了まで手を引く(F-EASY-1)。
                    // プロ用エディタは「くわしい設定を使う」からいつでも到達できる。
                    withAnimation(.easeInOut(duration: 0.25)) {
                        startedSimpleSetup = true
                    }
                } else {
                    dismiss()
                }
            }
        }
    }

    // MARK: 閉じる(右上)

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.05), in: Circle())
                }
                .padding(20)
            }
            Spacer()
        }
    }
}

// MARK: - テンプレートカード

/// 1枚ぶんのカード。大きめアイコン + displayName + caption。
/// 白カード+やわらかい影。押下時に軽くスケールダウンして押下感を出す
/// (スケールは CardButtonStyle が担当)。
private struct TemplateCard: View {
    let template: MappingPreset.ProjectTemplate
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                Image(systemName: template.systemImage)
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(Color.ccAccent)
                    .frame(height: 64)
                Text(template.displayName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(template.caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 260)
            .background(Color.ccCard, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.ccCardBorder, lineWidth: 1)
            )
            .ccCardShadow()
        }
        .buttonStyle(CardButtonStyle())
    }
}

/// 押下中に軽くスケールダウンするボタンスタイル。
private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }
}
