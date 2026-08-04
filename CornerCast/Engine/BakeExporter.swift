import AVFoundation
import CoreImage
import Metal

/// ベイク書き出し(F-BAKE-1)と管理(F-BAKE-3)。設計書§3.4参照。
///
/// 設計意図:
/// - ワープ処理は `FrameComposer.compose` をそのまま流用する。リアルタイムモードと
///   同一実装を通すことで「ベイク結果=リアルタイム表示」を構造的に保証する(独自ワープ禁止)。
/// - CIContextは1つを生成して使い回す(毎フレーム生成禁止・設計書§3.3/§3.4)。
struct BakeRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var sourceFileName: String
    var fileURL: URL
    var presetID: UUID
    var calibrationFingerprint: String
    var createdAt: Date
    var outputWidth: Int
    var outputHeight: Int
}

/// ベイク関連の失敗理由。async APIの3経路(完走/キャンセル/失敗)を型で表す。
enum BakeError: LocalizedError {
    case storageUnavailable
    case exportSessionCreationFailed
    /// 空き容量不足(F-BAKE-4)。required/availableはバイト。
    case insufficientStorage(required: Int64, available: Int64)
    case cancelled
    case failed(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "書き出し先ストレージにアクセスできません。"
        case .exportSessionCreationFailed:
            return "書き出しセッションを作成できませんでした。"
        case let .insufficientStorage(required, available):
            let req = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let avail = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "空き容量が不足しています(必要: 約\(req) / 空き: \(avail))。"
        case .cancelled:
            return "書き出しをキャンセルしました。"
        case let .failed(underlying):
            return "書き出しに失敗しました。\(underlying?.localizedDescription ?? "")"
        }
    }
}

// MARK: - 保存先の共有ヘルパ

/// BakeExporterとBakeStoreが同じ Documents/Bakes/ を指すための共通ロジック。
enum BakePaths {
    static let bakesDirectoryName = "Bakes"
    static let indexFileName = "index.json"

    /// Documents/Bakes/ のURL。無ければ作成する。取得不能時はnil。
    static func bakesDirectoryURL(fileManager: FileManager = .default) -> URL? {
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = docs.appendingPathComponent(bakesDirectoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func indexURL(fileManager: FileManager = .default) -> URL? {
        bakesDirectoryURL(fileManager: fileManager)?.appendingPathComponent(indexFileName)
    }
}

// MARK: - BakeExporter

final class BakeExporter {
    private let composer: FrameComposer

    /// 進捗(0.0-1.0)。バックグラウンドスレッドから呼ばれ得るため、
    /// UI更新に使う呼び出し側はメインアクタへディスパッチすること。
    var progressHandler: ((Double) -> Void)?

    /// キャンセル用に実行中のセッションを保持する。
    private var currentExport: AVAssetExportSession?

    // CIContextは使い回す(設計書§3.4)。Metalデバイスが取れればMetalバックエンドを使う。
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    init(composer: FrameComposer) {
        self.composer = composer
    }

    /// 現在のプリセットを適用した合成済み動画をアプリ内へ書き出す(F-BAKE-1)。
    /// - Returns: 書き出したファイルのメタデータ。呼び出し側でBakeStoreへ登録する。
    /// - Throws: 空き容量不足・キャンセル・書き出し失敗を `BakeError` で返す(3経路)。
    func export(sourceURL: URL, preset: MappingPreset, outputSize: CGSize) async throws -> BakeRecord {
        // 出力先: Documents/Bakes/<UUID>.mp4
        let recordID = UUID()
        guard let bakesDir = BakePaths.bakesDirectoryURL() else {
            throw BakeError.storageUnavailable
        }
        let outputURL = bakesDir.appendingPathComponent("\(recordID.uuidString).mp4")

        // 書き出し前に空き容量を確認する(F-BAKE-4)。出力解像度を必ず渡すこと。
        try await Self.checkFreeSpace(for: sourceURL, outputSize: outputSize)

        // 途中で失敗・キャンセルしたら書きかけのファイルを残さない。
        // Documents/Bakes/ 直下に書くため、残骸は index.json に載らず
        // UIからは見えないまま容量だけを食い続ける(アプリ削除以外に回収路がない)。
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: outputURL) }
        }

        let asset = AVURLAsset(url: sourceURL)

        // ワープ処理はFrameComposerを流用する。キャンバスは出力解像度(1080p/4K)で固定。
        let params = RenderParameters(canvasSize: outputSize, preset: preset)
        let composer = self.composer
        let context = self.ciContext

        // AVMutableVideoComposition(asset:applyingCIFiltersWithHandler:) はハンドラで
        // 毎フレームCIImageを受け取り、加工結果をrequest.finishで返す(iOS 9+)。
        let videoComposition = AVMutableVideoComposition(
            asset: asset,
            applyingCIFiltersWithHandler: { request in
                let composed = composer.compose(frame: request.sourceImage, params: params)
                request.finish(with: composed, context: context)
            })
        // 出力解像度をここで確定する(設計書§3.4)。
        videoComposition.renderSize = outputSize

        // 音声はExportSessionが自動でパススルーする(F-BAKE-1)。
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw BakeError.exportSessionCreationFailed
        }
        export.videoComposition = videoComposition
        export.outputFileType = .mp4
        export.outputURL = outputURL
        self.currentExport = export

        // 進捗をポーリングして通知する(F-BAKE-4)。
        // NOTE: iOS 18で導入された states(updateInterval:) / export(to:as:) は
        //       デプロイ先(iOS 17)で使えないため、従来型のprogressポーリングを用いる。
        //
        // 状態判定は「終端状態で抜ける」形にすること。以前は
        // `guard status == .waiting || .exporting else { break }` だったため、
        // exportAsynchronously を呼ぶ前の 1 周目に .unknown を観測すると
        // その場で break し、進捗バーが 0% のまま完了までフリーズしていた。
        let progressPoller = Task { [weak self, weak export] in
            while !Task.isCancelled {
                guard let export else { break }
                self?.progressHandler?(Double(export.progress))
                switch export.status {
                case .completed, .failed, .cancelled:
                    return
                default:
                    break   // .unknown / .waiting / .exporting は継続
                }
                try? await Task.sleep(nanoseconds: 250_000_000) // 0.25s
            }
        }
        defer {
            progressPoller.cancel()
            self.currentExport = nil
        }

        // 完走/キャンセル/失敗の3経路を継続で受ける。
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch export.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: BakeError.cancelled)
                case .failed:
                    continuation.resume(throwing: BakeError.failed(underlying: export.error))
                default:
                    // .unknown/.waiting/.exporting で完了ハンドラが呼ばれることは通常ないが、防御的に失敗扱い。
                    continuation.resume(throwing: BakeError.failed(underlying: export.error))
                }
            }
        }

        // 完了時に確実に1.0を通知しておく(ポーリングが取りこぼす可能性への保険)。
        progressPoller.cancel()
        self.progressHandler?(1.0)
        completed = true

        return BakeRecord(
            id: recordID,
            sourceFileName: sourceURL.lastPathComponent,
            fileURL: outputURL,
            presetID: preset.id,
            calibrationFingerprint: preset.calibrationFingerprint,
            createdAt: Date(),
            outputWidth: Int(outputSize.width.rounded()),
            outputHeight: Int(outputSize.height.rounded()))
    }

    /// 実行中の書き出しを中止する(F-BAKE-1)。呼ぶとexport(...)は BakeError.cancelled を投げる。
    func cancel() {
        currentExport?.cancelExport()
    }

    // MARK: - 空き容量チェック(F-BAKE-4)

    /// 出力解像度 × 尺 × 想定ビットレート で見積もり、Documentsボリュームの空きと比較する。
    ///
    /// 以前はソースサイズ×1.5だけで見ており、**出力解像度を完全に無視していた**。
    /// 1080pでも4Kでも同じ見積もりになるため、4K書き出しでは実測の1/2〜1/3しか見ておらず、
    /// F-BAKE-4 が警告を出す場合ですら表示される数値が誤っていた。
    private static func checkFreeSpace(for sourceURL: URL, outputSize: CGSize) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        let duration = seconds.isFinite && seconds > 0 ? seconds : 0

        let estimated: Int64
        if duration > 0 {
            // HEVC の実効ビットレート目安: 画素数に比例させる(1080p ≒ 12Mbps)。
            // 1920*1080 = 2,073,600 px に対し 12Mbps → 約 5.79 bps/px。
            let pixels = max(outputSize.width * outputSize.height, 1)
            let bitsPerSecond = Double(pixels) * 5.79
            // 安全率1.3(可変ビットレートの山と音声トラックぶん)
            estimated = Int64(bitsPerSecond * duration / 8.0 * 1.3)
        } else {
            // 尺が取れないときは従来どおりソースサイズから概算する
            let sourceBytes = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            estimated = Int64(Double(sourceBytes) * 1.5)
        }

        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else {
            throw BakeError.storageUnavailable
        }
        // volumeAvailableCapacityForImportantUsageKey は「重要な用途」向けの実効空き容量(Int64バイト)。
        let values = try docs.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           estimated > available {
            throw BakeError.insufficientStorage(required: estimated, available: available)
        }
    }
}

// MARK: - BakeStore

/// ベイク済み動画のメタデータ管理(F-BAKE-3)。Documents/Bakes/index.json で永続化する。
final class BakeStore {
    private let fileManager: FileManager

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

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// 索引が読めなかったことを表す。`list()` の「空」と区別するために使う。
    struct IndexUnreadable: Error {}

    func list() -> [BakeRecord] {
        (try? loadRecords()) ?? []
    }

    /// 索引を読む。**「空」と「読めない」を区別すること。**
    /// index.json は単一のJSON配列なので、1レコードの不整合でデコード全体が落ちる。
    /// これを `?? []` で潰したまま add/delete の read-modify-write を続けると、
    /// 次の書き込みで**全レコードが消え**、実体のmp4だけがUIから見えないゴミとして残る。
    private func loadRecords() throws -> [BakeRecord] {
        guard let dir = BakePaths.bakesDirectoryURL(fileManager: fileManager),
              let url = BakePaths.indexURL(fileManager: fileManager) else {
            throw BakeError.storageUnavailable
        }
        guard let data = try? Data(contentsOf: url) else {
            return []   // 索引がまだ無い = 空。これは正常。
        }
        guard let records = try? decoder.decode([BakeRecord].self, from: data) else {
            throw IndexUnreadable()
        }
        // アプリのサンドボックス絶対パスは再インストール等でコンテナUUIDが変わり得るため、
        // 保存済みfileURLをそのまま信頼せず、現在のBakesディレクトリ+ファイル名で再構成する(N-REL-1)。
        return records.map { record in
            var updated = record
            updated.fileURL = dir.appendingPathComponent(record.fileURL.lastPathComponent)
            return updated
        }
    }

    /// レコードを追加(同一IDは置き換え)。索引が読めない場合は退避して作り直す。
    func add(_ record: BakeRecord) throws {
        var records = try recordsForMutation()
        records.removeAll { $0.id == record.id }
        records.append(record)
        try writeIndex(records)
    }

    /// レコードと実体ファイルを削除する。
    /// **索引を先に書いてから実体を消すこと。** 逆順だと writeIndex が失敗したときに
    /// 「実体を失ったレコードが索引に残る」状態になり、再生時に破綻する。
    func delete(id: UUID) throws {
        var records = try recordsForMutation()
        let removed = records.first { $0.id == id }
        records.removeAll { $0.id == id }
        try writeIndex(records)
        if let removed {
            try? fileManager.removeItem(at: removed.fileURL)
        }
    }

    /// 書き換え前の索引読み出し。読めない場合は破損ファイルを退避したうえで、
    /// Bakes/ の実走査から索引を復元する。全件を黙って捨てない。
    private func recordsForMutation() throws -> [BakeRecord] {
        do {
            return try loadRecords()
        } catch is IndexUnreadable {
            try? quarantineCorruptIndex()
            return rebuildIndexFromDisk()
        }
    }

    /// 壊れた索引を index.corrupt-<時刻>.json へ退避する(上書きで失わないため)。
    private func quarantineCorruptIndex() throws {
        guard let url = BakePaths.indexURL(fileManager: fileManager) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("index.corrupt-\(stamp).json")
        try? fileManager.moveItem(at: url, to: backup)
    }

    /// Bakes/ 直下の mp4 を実走査して索引を組み直す。
    /// fingerprint は復元できないので、必ず「再書き出しが必要」と判定される値を入れる。
    private func rebuildIndexFromDisk() -> [BakeRecord] {
        guard let dir = BakePaths.bakesDirectoryURL(fileManager: fileManager),
              let urls = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        return urls
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .map { url in
                let created = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? Date()
                return BakeRecord(
                    id: UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID(),
                    sourceFileName: url.lastPathComponent,
                    fileURL: url,
                    presetID: UUID(),
                    calibrationFingerprint: "recovered",
                    createdAt: created,
                    outputWidth: 0,
                    outputHeight: 0)
            }
    }

    /// 生成時プリセットと現在のプリセットのfingerprint比較(F-BAKE-3の「再書き出しが必要」判定)。
    func isStale(_ record: BakeRecord, currentPreset: MappingPreset) -> Bool {
        record.calibrationFingerprint != currentPreset.calibrationFingerprint
    }

    // MARK: - 内部ヘルパ

    private func writeIndex(_ records: [BakeRecord]) throws {
        guard let url = BakePaths.indexURL(fileManager: fileManager) else {
            throw BakeError.storageUnavailable
        }
        let data = try encoder.encode(records)
        try data.write(to: url, options: .atomic)
    }
}
