import SwiftUI

/// ユースケース選択(F-TPL-1)。初回起動時(viewModel.needsWelcome)と
/// ツールバー「新規」から表示する。
///
/// デザイン: 黒基調のフルスクリーン。タイトル + サブタイトルの下に
/// ProjectTemplate.allCases の3枚カードを並べる(横幅が広ければ横並び、
/// 狭ければ縦積み)。カードタップで軽い押下スケール → apply(template:) → dismiss。
/// 右上「閉じる」で現在のプリセットのまま抜けられる(スキップ可能)。
struct WelcomeView: View {
    @Bindable var viewModel: MappingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            closeButton
        }
        .preferredColorScheme(.dark)
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
                .foregroundStyle(.white)
            Text("どこから始めますか?")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
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
                dismiss()
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
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .padding(20)
            }
            Spacer()
        }
    }
}

// MARK: - テンプレートカード

/// 1枚ぶんのカード。大きめアイコン + displayName + caption。
/// 押下時に軽くスケールダウンして押下感を出す(スケールは CardButtonStyle が担当)。
private struct TemplateCard: View {
    let template: MappingPreset.ProjectTemplate
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                Image(systemName: template.systemImage)
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.white)
                    .frame(height: 64)
                Text(template.displayName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text(template.caption)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
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
