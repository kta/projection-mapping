import Foundation
import CoreGraphics
import Network

/// 外部制御(F-CTRL-1: OSC / F-CTRL-2: MIDI)の統括。
/// 設定(UserDefaults)に従いOSCServer/MIDIControllerを起動・停止し、
/// 受信メッセージをMainActor上でMappingViewModelへ適用する。
///
/// 実装(TASK CTRL-1):
/// - UserDefaultsキー: "control.osc.enabled"(Bool) / "control.osc.port"(Int, 既定8000) /
///   "control.midi.enabled"(Bool)
/// - start(): 設定を読み、有効なものを起動。stop(): 全停止。いずれも冪等。
/// - applySettings(...): 保存して再起動。
/// - 受信→ViewModel適用はすべて `Task { @MainActor in ... }` 経由(スレッド安全)。
/// - OSCアドレス空間はdocs/06 §5.1を厳守(テストと共有する契約)。
@MainActor
final class ControlHub {
    private let viewModel: MappingViewModel
    private var oscServer: OSCServer?
    private var midiController: MIDIController?

    private(set) var isRunning = false

    private enum Keys {
        static let oscEnabled = "control.osc.enabled"
        static let oscPort = "control.osc.port"
        static let midiEnabled = "control.midi.enabled"
    }

    /// 有効ポート範囲(ControlSettingsViewの検証と一致させる)
    static let portRange: ClosedRange<Int> = 1024...65535
    static let defaultPort = 8000

    init(viewModel: MappingViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - 設定読み出し(ControlSettingsViewが初期表示に使う)

    var oscEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.oscEnabled) as? Bool ?? false
    }

    var oscPort: Int {
        UserDefaults.standard.object(forKey: Keys.oscPort) as? Int ?? Self.defaultPort
    }

    var midiEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.midiEnabled) as? Bool ?? false
    }

    // MARK: - ライフサイクル

    /// 設定を読み、有効な制御を起動する。再入時は先に停止するため冪等。
    func start() {
        stop()

        if oscEnabled {
            let clampedPort = min(max(oscPort, Self.portRange.lowerBound), Self.portRange.upperBound)
            let server = OSCServer(port: UInt16(clampedPort))
            server.messageHandler = { [weak self] message in
                // ハンドラはバックグラウンドスレッドから呼ばれる。適用は必ずMainActor経由。
                Task { @MainActor in
                    self?.apply(osc: message)
                }
            }
            do {
                try server.start()
                oscServer = server
            } catch {
                oscServer = nil
            }
        }

        if midiEnabled {
            // MIDI受信は現状スタブ(下記MIDIController参照)。有効化しても実イベントは流れないが、
            // 実装が入り次第このハンドラ結線でViewModelへ適用される(§5.2)。
            let controller = MIDIController()
            controller.eventHandler = { [weak self] event in
                Task { @MainActor in
                    self?.apply(midi: event)
                }
            }
            do {
                try controller.start()
                midiController = controller
            } catch {
                midiController = nil
            }
        }

        // MIDIは未実装スタブのため、稼働表示はOSCサーバの起動可否に紐付ける。
        isRunning = oscServer != nil
    }

    /// 全停止。冪等。
    func stop() {
        oscServer?.stop()
        oscServer = nil
        midiController?.stop()
        midiController = nil
        isRunning = false
    }

    /// 設定を保存して再起動する。
    func applySettings(oscEnabled: Bool, oscPort: Int, midiEnabled: Bool) {
        let d = UserDefaults.standard
        d.set(oscEnabled, forKey: Keys.oscEnabled)
        d.set(oscPort, forKey: Keys.oscPort)
        d.set(midiEnabled, forKey: Keys.midiEnabled)
        start()
    }

    // MARK: - OSC適用(docs/06 §5.1・変更禁止の契約)

    /// 受信OSCメッセージをViewModelへ適用する。未知アドレスは無視。値はクランプ。
    private func apply(osc message: OSCMessage) {
        // "/cc/..." を "/" 区切りで分解(split は空要素を落とす)
        let comps = message.address.split(separator: "/").map(String.init)
        guard comps.first == "cc", comps.count >= 2 else { return }
        let floats = message.floats

        switch comps[1] {
        case "corner":
            // /cc/corner/<surface>/<tl|tr|br|bl>  ff (x, y 0-1)
            guard comps.count == 4,
                  let surface = Self.surface(from: comps[2]),
                  let corner = Self.corner(from: comps[3]),
                  floats.count >= 2 else { return }
            let x = Double(Self.clamp(floats[0], 0, 1))
            let y = Double(Self.clamp(floats[1], 0, 1))
            viewModel.move(corner: corner, of: surface, to: CGPoint(x: x, y: y))

        case "brightness":
            guard comps.count == 3,
                  let surface = Self.surface(from: comps[2]),
                  let v = floats.first else { return }
            viewModel.preset.surfaces[surface]?.brightness = Double(Self.clamp(v, 0.25, 2))

        case "gamma":
            guard comps.count == 3,
                  let surface = Self.surface(from: comps[2]),
                  let v = floats.first else { return }
            viewModel.preset.surfaces[surface]?.gamma = Double(Self.clamp(v, 0.25, 4))

        case "feather":
            guard comps.count == 3,
                  let surface = Self.surface(from: comps[2]),
                  let v = floats.first else { return }
            viewModel.preset.surfaces[surface]?.feather = Double(Self.clamp(v, 0, 0.3))

        case "play":
            viewModel.activeVideoSource?.play()

        case "pause":
            viewModel.activeVideoSource?.pause()

        case "mode":
            // i (0=realtime, 1=baked)
            guard let v = floats.first else { return }
            viewModel.outputMode = Int(v.rounded()) == 1 ? .bakedPlayback : .realtime

        default:
            return
        }
    }

    // MARK: - MIDI適用(docs/06 §5.2)

    /// 受信MIDIイベントを固定マッピングでViewModelへ適用する。
    /// (MIDIController実装後に有効化。範囲外は現在の選択が無ければ無視)
    private func apply(midi event: MIDIControlEvent) {
        switch event {
        case .controlChange(let number, let value):
            let norm = Double(value) / 127.0
            switch number {
            case 20, 21:
                // 選択中頂点のX / Y
                guard let s = viewModel.selectedSurface,
                      let c = viewModel.selectedCorner,
                      let current = viewModel.preset.surfaces[s]?.quad[c] else { return }
                let p = number == 20
                    ? CGPoint(x: norm, y: current.y)
                    : CGPoint(x: current.x, y: norm)
                viewModel.move(corner: c, of: s, to: p)
            case 22:
                // 選択中面の明るさ(0-127 → 0.25-2.0)
                guard let s = viewModel.selectedSurface else { return }
                viewModel.preset.surfaces[s]?.brightness = 0.25 + norm * (2.0 - 0.25)
            case 23:
                // 選択中面のガンマ(0-127 → 0.25-4.0)
                guard let s = viewModel.selectedSurface else { return }
                viewModel.preset.surfaces[s]?.gamma = 0.25 + norm * (4.0 - 0.25)
            default:
                return
            }
        case .noteOn(let note):
            if note == 60 { viewModel.activeVideoSource?.play() }
            else if note == 61 { viewModel.activeVideoSource?.pause() }
        }
    }

    // MARK: - マッピングヘルパ

    private static func surface(from token: String) -> Surface? {
        Surface(rawValue: token)
    }

    /// OSCアドレスの短縮コーナー名(tl/tr/br/bl)→ Quad.Corner
    private static func corner(from token: String) -> Quad.Corner? {
        switch token {
        case "tl": return .topLeft
        case "tr": return .topRight
        case "br": return .bottomRight
        case "bl": return .bottomLeft
        default: return nil
        }
    }

    private static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        min(max(v, lo), hi)
    }
}

/// OSC受信サーバ(F-CTRL-1)。UDPで待ち受け、OSCパケットをパースする。
///
/// - Network.framework(NWListener, .udp)で指定ポートを待ち受ける。
/// - パースは OSCMessage.parse(純関数)を使う。
/// - messageHandler は **バックグラウンドキュー(内部の専用DispatchQueue)から** 呼ばれる。
///   ViewModel適用側で必ずMainActorへ載せ替えること。
final class OSCServer {
    /// バックグラウンドキューから呼ばれる。Sendableクロージャとして扱う。
    var messageHandler: (@Sendable (OSCMessage) -> Void)?

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.cornercast.osc.server")

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 8000)
    }

    func start() throws {
        stop()
        let listener = try NWListener(using: .udp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.setup(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func setup(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection)
    }

    /// UDPデータグラム単位で受信し、パース成功時にハンドラへ渡す。
    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty, let message = OSCMessage.parse(data) {
                self?.messageHandler?(message)
            }
            if error == nil {
                self?.receive(on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    /// 冪等な停止。
    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// OSCメッセージ(パース済み)。パースは**純関数**でユニットテスト可能(契約)。
/// 対応型タグ: f(float32) / i(int32→Floatへ変換) のみ。他はスキップする。
struct OSCMessage: Equatable {
    var address: String
    var floats: [Float]

    /// OSCパケット(単一メッセージ)をパースする。バンドル(#bundle)は未対応でnil。
    /// OSC 1.0仕様: アドレス(null終端・4バイト境界パディング)、","で始まる型タグ列(同)、
    /// 引数(ビッグエンディアン)。不正データはnil。
    static func parse(_ data: Data) -> OSCMessage? {
        let bytes = [UInt8](data)

        // 1. アドレスパターン(OSC-string)
        guard let (address, afterAddress) = readOSCString(bytes, 0) else { return nil }
        // アドレスは "/" 始まり。"#bundle" 等(バンドル/不正)は弾く。
        guard address.hasPrefix("/") else { return nil }

        // 2. 型タグ列。無ければ引数なしメッセージ(末尾に到達している場合のみ許容)。
        guard let (typeTags, afterTags) = readOSCString(bytes, afterAddress) else {
            return afterAddress == bytes.count ? OSCMessage(address: address, floats: []) : nil
        }
        guard typeTags.hasPrefix(",") else { return nil }

        // 3. 引数(ビッグエンディアン、各4バイト)
        var floats: [Float] = []
        var offset = afterTags
        for tag in typeTags.dropFirst() {
            switch tag {
            case "f":
                guard let bits = readUInt32BE(bytes, offset) else { return nil }
                floats.append(Float(bitPattern: bits))
                offset += 4
            case "i":
                guard let bits = readUInt32BE(bytes, offset) else { return nil }
                floats.append(Float(Int32(bitPattern: bits)))
                offset += 4
            default:
                // 未対応型タグはスキップ(引数長が不明なため読み飛ばさず無視する)
                continue
            }
        }
        return OSCMessage(address: address, floats: floats)
    }

    /// OSC-string を読む。null終端+4バイト境界パディング。次のオフセットを返す。
    private static func readOSCString(_ bytes: [UInt8], _ start: Int) -> (String, Int)? {
        guard start >= 0, start < bytes.count else { return nil }
        var end = start
        while end < bytes.count, bytes[end] != 0 { end += 1 }
        guard end < bytes.count else { return nil } // null終端が無ければ不正
        let length = end - start
        guard let string = String(bytes: bytes[start..<end], encoding: .utf8) else { return nil }
        // フィールド長 = 4の倍数(null含めて最低1バイトのパディング)
        let field = (length / 4 + 1) * 4
        return (string, start + field)
    }

    /// ビッグエンディアン UInt32 を読む。範囲外は nil。
    private static func readUInt32BE(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}

/// MIDI受信(F-CTRL-2)。固定マッピング(docs/06 §5.2)でViewModelを操作する。
///
/// 実装状況(TASK CTRL-1): **無効スタブ**。
/// CoreMIDIの受信API(MIDIInputPortCreateWithProtocol / MIDIReceiveBlock による
/// MIDIEventList のパース)は本タスクのスコープでシグネチャに確信が持てないため、
/// 発明を避けて未実装のまま残す(docs/06 §5.2の指示どおり)。
/// ControlHub側の適用ロジック(apply(midi:))とeventHandler結線は実装済みのため、
/// 本クラスがMIDIControlEventを emit するようになれば即座に機能する。
final class MIDIController {
    /// バックグラウンドスレッドから呼ばれる想定(Sendable)。
    var eventHandler: (@Sendable (MIDIControlEvent) -> Void)?

    func start() throws {
        // TODO(CTRL-1): CoreMIDIでの入力受信。QUESTIONS参照。
    }

    func stop() {
        // no-op(スタブ)
    }
}

/// MIDI由来の抽象イベント(テスト可能な中間表現)
enum MIDIControlEvent: Equatable {
    case controlChange(number: UInt8, value: UInt8)
    case noteOn(note: UInt8)
}
