import SwiftUI

/// アプリ内ヘルプ(N-INST-1: 設置ガイド、R1〜R8のユーザー向け対策)。
/// 内容は要件定義書・技術調査レポートの確定事項に基づく。
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                quickStartSection
                placementSection
                hardwareSection
                modeSection
                troubleshootingSection
            }
            .navigationTitle("ヘルプ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func item(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).bold()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: セクション

    private var quickStartSection: some View {
        Section("クイックスタート") {
            item("1. プロジェクターを設置",
                 "部屋の右後方・天井付近から、左壁・正面壁・床のコーナーへ斜めに投影します。")
            item("2. iPad/MacをHDMI接続",
                 "USB-C – HDMIアダプタで接続すると、プロジェクター側に映像が自動で全画面表示されます。")
            item("3. テストパターンで調整",
                 "ツールバーの「テストパターン」を投影し、キャンバス上の12個の点をドラッグして各面のグリッドを部屋の面に合わせます。矢印キーで±1px、Shift+矢印で±10pxの微調整もできます。")
            item("4. プリセット保存",
                 "調整結果は自動保存されます。「プリセット」から名前を付けて保存すれば、複数の設置環境を切り替えられます。")
            item("5. コンテンツを投影",
                 "「コンテンツ」から動画・画像を選ぶと、3分割→射影変換→合成されて投影されます。クロップ編集で各面への割り当て領域を調整できます。")
            item("6. 長時間観るならベイク",
                 "「この設定で書き出し」で合成済み動画を作成し、ベイク再生モードに切り替えると低負荷・低発熱で長時間投影できます。")
        }
    }

    private var placementSection: some View {
        Section("設置のコツ") {
            item("投射角は30度以内を目安に",
                 "各面に対する投射角が大きいほどフォーカスの不均一と画質低下が進みます。プロジェクターはできるだけ面に正対する位置に。")
            item("光路はユーザーの頭上を通す",
                 "座席がプロジェクターの光路に近いと、身を乗り出したときに床・正面壁へ影が落ちます。天井付近の高い位置からの投影を推奨します。")
            item("超短焦点(UST)機は使用不可",
                 "UST機は傾け設置ができず(フォーカス・輝度損失が補正不能)、本アプリの斜め投影構成には適合しません。通常投射比の機種を使用してください。")
            item("フォーカスは中間距離に合わせる",
                 "3面で投射距離が異なるため全面同時にピントは合いません。最も見る面(通常は正面壁)を優先し、残りは被写界深度でカバーします。レーザー光源機が有利です。")
            item("台形補正は画質と引き換え",
                 "本アプリの射影変換もプロジェクター内蔵のデジタル補正も、原理的に実効解像度が下がります。補正量が小さくなる設置ほど高画質です。")
        }
    }

    private var hardwareSection: some View {
        Section("接続と機材") {
            item("推奨アダプタ",
                 "HDMI 2.0対応のUSB-C(DisplayPort Alt Mode)アダプタ+PD給電パススルー付きを推奨。給電しながら投影できます。")
            item("Apple純正Multiportアダプタの注意",
                 "純正USB-C Digital AV Multiportアダプタはアプリの描画を1080pに制限します(4K60になるのは動画プレーヤー系コンテンツのみ)。4K投影にはサードパーティ製HDMI 2.0アダプタを使用してください。")
            item("4K60で出力できる機種",
                 "iPad Pro全機種 / iPad Air(M2以降・第5世代) / iPad mini(A17 Pro) / iPad(A16)。iPad Air第4世代・mini第6世代・iPad第10世代は4K30までです。")
            item("AirPlayは非推奨",
                 "無線出力は1〜3秒の遅延があり、キャリブレーション操作に向きません。有線HDMIを使用してください。")
        }
    }

    private var modeSection: some View {
        Section("モードの使い分け") {
            item("リアルタイムモード",
                 "ツマミ操作が即座に投影へ反映されます。キャリブレーション作業と、コンテンツをすぐ試したいときに。連続GPU負荷により十数分で発熱制限が始まる場合があります(自動で解像度を下げて継続します)。")
            item("ベイク再生モード",
                 "調整結果を適用済みの動画を再生するだけなので、低負荷・低発熱で何時間でも投影できます。映画鑑賞など長時間の利用はこちらが既定です。調整を変えたら「再書き出し推奨」バッジが出ます。")
        }
    }

    private var troubleshootingSection: some View {
        Section("トラブルシューティング") {
            item("プロジェクターにiPadの画面がそのまま映る",
                 "接続直後は一時的にミラーリング表示になることがあります。アプリがフォアグラウンドにあることを確認し、ケーブルを挿し直してください。")
            item("外部出力の確認にQuickTime録画は使えない",
                 "Mac経由のキャプチャでは外部ディスプレイ用の映像シーンが生成されず、動作確認できません。必ず実際のHDMI接続で確認してください。")
            item("出力が1080pになる",
                 "アダプタがHDMI 2.0対応か、純正Multiportアダプタを使っていないかを確認してください(上記「接続と機材」参照)。")
            item("映像がカクつく",
                 "リアルタイムモードで4K/60pソースを使うと機種によっては処理が追いつきません。1080pソースにするか、ベイク再生モードをご利用ください。")
        }
    }
}
