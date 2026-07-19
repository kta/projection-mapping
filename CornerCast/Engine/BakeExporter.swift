import AVFoundation
import CoreImage

/// ベイク書き出し(F-BAKE-1)と管理(F-BAKE-3)。設計書§3.4参照。
///
/// TODO(TASK ENG-5 / 担当: persistence agent):
/// BakeExporter:
/// - export(sourceURL:preset:outputSize:) async throws -> BakeRecord
///   * AVMutableVideoComposition(asset:applyingCIFiltersWithHandler:) のハンドラ内で
///     FrameComposer.compose(frame: request.sourceImage, params:) を呼び、
///     request.finish(with:context:) で返す。CIContextは1つを使い回す。
///   * renderSizeにoutputSizeを設定。
///   * AVAssetExportSession(preset: AVAssetExportPresetHEVCHighestQuality)、outputFileType .mp4。
///     音声はExportSessionが自動でパススルーする。
///   * 進捗: progressHandler(0.0-1.0)を定期的に呼ぶ(export.progressをポーリング)。
///   * キャンセル: cancel()でexport.cancelExport()。
/// - 出力先: Documents/Bakes/<UUID>.mp4
///
/// BakeStore:
/// - BakeRecord(id, sourceURL, fileURL, presetID, calibrationFingerprint, createdAt, outputSize)
///   をDocuments/Bakes/index.jsonで管理。
/// - isStale(record:currentPreset:) = record.calibrationFingerprint != preset.calibrationFingerprint
///   (F-BAKE-3の「再書き出しが必要」判定)。
/// - 空き容量チェック(F-BAKE-4): FileManagerのvolumeAvailableCapacityForImportantUsageKey。
///   見積もりサイズはソースファイルサイズ×1.5を仮の目安とする。
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

final class BakeExporter {
    private let composer: FrameComposer

    var progressHandler: ((Double) -> Void)?

    init(composer: FrameComposer) {
        self.composer = composer
    }

    func export(sourceURL: URL, preset: MappingPreset, outputSize: CGSize) async throws -> BakeRecord {
        // TODO: ENG-5
        throw NSError(domain: "BakeExporter", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "未実装(ENG-5)"])
    }

    func cancel() {
        // TODO: ENG-5
    }
}

final class BakeStore {
    func list() -> [BakeRecord] {
        [] // TODO: ENG-5
    }

    func add(_ record: BakeRecord) throws {
        // TODO: ENG-5
    }

    func delete(id: UUID) throws {
        // TODO: ENG-5
    }

    func isStale(_ record: BakeRecord, currentPreset: MappingPreset) -> Bool {
        record.calibrationFingerprint != currentPreset.calibrationFingerprint
    }
}
