import Foundation

/// プリセット永続化(F-PRESET-1〜3)。プロトコルはViewModelが依存するため変更禁止。
protocol PresetStoreProtocol: AnyObject {
    /// 前回終了時の状態(F-PRESET-2)。初回起動時はnil。
    func loadLastUsed() -> MappingPreset?
    func saveLastUsed(_ preset: MappingPreset)

    /// 名前付きプリセット(F-PRESET-1)
    func listPresets() -> [MappingPreset]
    func save(_ preset: MappingPreset) throws
    func delete(id: UUID) throws

    /// 外部から持ち込まれたJSONを読む(F-PRESET-3)。
    /// **UI側で JSONDecoder を直に使わないこと** — schemaVersion のゲートと
    /// 値域・件数の正規化を迂回してしまう。
    func decodeImported(_ data: Data) throws -> (preset: MappingPreset, adjusted: Bool)

    /// 直近の自動保存が失敗していればその理由。成功していれば nil。
    /// 自動保存は throw しない代わりに、失敗を観測できる口をここに用意する。
    var lastAutosaveErrorMessage: String? { get }
}

/// 永続化に固有のエラー。破損JSONはnil/空配列で握りつぶす(N-REL-1)一方、
/// 明示的な保存/削除の失敗は呼び出し側(UI)へ通知したいため型で区別する。
enum PresetStoreError: LocalizedError {
    case documentsDirectoryUnavailable
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case malformedJSON

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "保存先ディレクトリにアクセスできません。"
        case let .unsupportedSchemaVersion(found, supported):
            return "このプリセットは新しい形式(v\(found))で保存されています。"
                + "このバージョンのCornerCastはv\(supported)まで対応しています。"
                + "アプリを最新版に更新してください。"
        case .malformedJSON:
            return "プリセットとして読み取れないファイルです。"
        }
    }
}

/// Documents/Presets/ 以下にJSONで保存する実装。
/// - 名前付きプリセット: <UUID>.json
/// - 前回状態(自動保存): lastUsed.json(固定名)
final class PresetStore: PresetStoreProtocol {

    // MARK: 保存先の規約

    private static let presetsDirectoryName = "Presets"
    private static let lastUsedFileName = "lastUsed.json"

    private let fileManager: FileManager

    // JSONEncoder/Decoderは日付を.iso8601で扱う(要件§8のupdatedAtがISO8601形式のため)。
    // .sortedKeysはテストでの出力固定と差分の安定化のために付与している。
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 保存先のルート。nil なら Documents を使う。
    /// テストは一時ディレクトリを渡すこと — 既定のままだと本番の lastUsed.json を
    /// 実際に上書きしてしまい、実機で調整した内容がテスト実行で消える。
    private let rootDirectory: URL?

    private(set) var lastAutosaveErrorMessage: String?

    /// AppServicesは引数なしで生成するため、いずれもデフォルト引数で受ける。
    init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
    }

    // MARK: - PresetStoreProtocol

    func loadLastUsed() -> MappingPreset? {
        guard let url = lastUsedFileURL() else { return nil }
        return decodePreset(at: url)
    }

    func saveLastUsed(_ preset: MappingPreset) {
        // 自動保存はプロトコル上throwしない(N-REL-1)。ただし**失敗を隠さない**:
        // 握りつぶしたままだと、ディスクフル等で保存が効いていないことに
        // ユーザーが気づけず、長時間の調整を積み上げた末に再起動で失う。
        guard let url = lastUsedFileURL() else {
            lastAutosaveErrorMessage = PresetStoreError.documentsDirectoryUnavailable.localizedDescription
            return
        }
        do {
            try writePreset(preset, to: url)
            lastAutosaveErrorMessage = nil
        } catch {
            lastAutosaveErrorMessage = error.localizedDescription
        }
    }

    /// 外部JSONの読み込み(F-PRESET-3)。schemaVersion のゲートと正規化を必ず通す。
    func decodeImported(_ data: Data) throws -> (preset: MappingPreset, adjusted: Bool) {
        guard let raw = try? decoder.decode(MappingPreset.self, from: data) else {
            throw PresetStoreError.malformedJSON
        }
        guard raw.schemaVersion <= MappingPreset.currentSchemaVersion else {
            throw PresetStoreError.unsupportedSchemaVersion(
                found: raw.schemaVersion, supported: MappingPreset.currentSchemaVersion)
        }
        let result = raw.sanitized()
        return (result.preset, result.changed)
    }

    func listPresets() -> [MappingPreset] {
        guard let dir = presetsDirectoryURL(),
              let urls = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        // lastUsed.json(自動保存)は名前付きプリセット一覧には含めない。
        // 破損ファイルはdecodePresetがnilを返すのでcompactMapで自然に除外される(N-REL-1)。
        return urls
            .filter { $0.pathExtension.lowercased() == "json"
                && $0.lastPathComponent != Self.lastUsedFileName }
            .compactMap { decodePreset(at: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ preset: MappingPreset) throws {
        guard let dir = presetsDirectoryURL() else {
            throw PresetStoreError.documentsDirectoryUnavailable
        }
        let url = dir.appendingPathComponent("\(preset.id.uuidString).json")
        try writePreset(preset, to: url)
    }

    func delete(id: UUID) throws {
        guard let dir = presetsDirectoryURL() else {
            throw PresetStoreError.documentsDirectoryUnavailable
        }
        let url = dir.appendingPathComponent("\(id.uuidString).json")
        // 既に存在しない場合は成功扱い(冪等)。
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - 内部ヘルパ

    /// Presets/ のURL。無ければ作成する。取得・作成できなければnil。
    /// 作成に失敗したまま非nilを返すと、以後の書き込みが毎回失敗し続けて理由も残らない。
    private func presetsDirectoryURL() -> URL? {
        let base: URL
        if let rootDirectory {
            base = rootDirectory
        } else if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            base = docs
        } else {
            return nil
        }
        let dir = base.appendingPathComponent(Self.presetsDirectoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return dir
    }

    private func lastUsedFileURL() -> URL? {
        presetsDirectoryURL()?.appendingPathComponent(Self.lastUsedFileName)
    }

    private func writePreset(_ preset: MappingPreset, to url: URL) throws {
        let data = try encoder.encode(preset)
        // .atomicで書き込み途中のプロセス終了による破損を避ける。
        try data.write(to: url, options: .atomic)
    }

    /// 読み込み。破損JSON・読み取り不能・未対応スキーマはすべてnilを返しクラッシュしない(N-REL-1)。
    /// 読めたものは必ず sanitized() を通す — 値域外の値がそのまま合成へ流れると
    /// 面が真っ白になったり消えたりし、しかもスライダーからは直せなくなる。
    private func decodePreset(at url: URL) -> MappingPreset? {
        guard let data = try? Data(contentsOf: url),
              let preset = try? decoder.decode(MappingPreset.self, from: data) else {
            return nil
        }
        // 将来のschemaVersion(このビルドが知らない形式)は読み込みを拒否する。
        // 未知フィールドを既定値で埋めて誤動作するより、明示的に非対応とする方が安全。
        guard preset.schemaVersion <= MappingPreset.currentSchemaVersion else {
            return nil
        }
        return preset.sanitized().preset
    }
}
