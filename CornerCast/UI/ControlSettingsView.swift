import SwiftUI

/// 外部制御設定(F-CTRL-1/2)シート。OSC/MIDIの有効化とポート設定。
///
/// TODO(TASK CTRL-1 / 担当: control agent):
/// - OSC: 有効Toggle+ポートTextField(1024-65535検証)。適用でControlHub再起動。
/// - MIDI: 有効Toggle。
/// - OSCアドレス一覧(docs/06 §5.1)とMIDI固定マッピング(§5.2)をヘルプとして表示。
/// - 状態はAppServices.shared.controlHub経由。
struct ControlSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Text("TODO: CTRL-1 ControlSettingsView") // TODO: CTRL-1
    }
}
