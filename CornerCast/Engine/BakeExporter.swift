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

        // 書き出し前に空き容量を確認する(F-BAKE-4)。
        try Self.checkFreeSpace(for: sourceURL)

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
        let progressPoller = Task { [weak self, weak export] in
            while !Task.isCancelled {
                guard let export else { break }
                self?.progressHandler?(Double(export.progress))
                // .waiting / .exporting の間だけ継続。完了・失敗・キャンセルで抜ける。
                guard export.status == .waiting || export.status == .exporting else { break }
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

    /// ソースサイズ×1.5を見積もりとし、Documentsボリュームの空きと比較する。
    /// 見積もりは仮の目安(設計書TODO準拠)。実サイズは再エンコード結果に依存する。
    private static func checkFreeSpace(for sourceURL: URL) throws {
        let sourceBytes = (try? sourceURL.resourceValues(
            forKeys: [.fileSizeKey]).fileSize) ?? 0
        let estimated = Int64(Double(sourceBytes) * 1.5)

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

    func list() -> [BakeRecord] {
        guard let dir = BakePaths.bakesDirectoryURL(fileManager: fileManager),
              let url = BakePaths.indexURL(fileManager: fileManager),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        let records = (try? decoder.decode([BakeRecord].self, from: data)) ?? []
        // アプリのサンドボックス絶対パスは再インストール等でコンテナUUIDが変わり得るため、
        // 保存済みfileURLをそのまま信頼せず、現在のBakesディレクトリ+ファイル名で再構成する(N-REL-1)。
        return records.map { record in
            var updated = record
            updated.fileURL = dir.appendingPathComponent(record.fileURL.lastPathComponent)
            return updated
        }
    }

    /// レコードを追加(同一IDは置き換え)。
    func add(_ record: BakeRecord) throws {
        var records = list()
        records.removeAll { $0.id == record.id }
        records.append(record)
        try writeIndex(records)
    }

    /// レコードと実体ファイルを削除する。
    func delete(id: UUID) throws {
        var records = list()
        if let index = records.firstIndex(where: { $0.id == id }) {
            let removed = records.remove(at: index)
            // 動画本体も削除(存在しなくてもエラーにしない)。
            try? fileManager.removeItem(at: removed.fileURL)
        }
        try writeIndex(records)
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
