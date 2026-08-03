import XCTest
import AVFoundation
import Foundation
@testable import CornerCast

// 同梱サンプル動画(F-SRC-7)がバンドルに実在し、再生可能で、
// デフォルトクロップ(F-CROP-1)の前提を満たすことを固定する。
//
// SampleVideo.available は url が nil のものを黙って落とす設計のため、
// リソースのコピー漏れ・リネーム・ターゲットメンバーシップ外しが起きても
// 「コンテンツ選択からサンプル欄が消えるだけ」でビルドもテストも通ってしまう。
// その沈黙を破るのがこのテストの役目。

final class SampleVideoBundlingTests: XCTestCase {

    /// 宣言した全サンプルがバンドルから解決できること。
    /// ここが落ちたらリソースが .app に入っていない(= アプリ上でサンプル欄が消える)。
    func testAllDeclaredSamplesResolveInBundle() {
        let missing = SampleVideo.all.filter { $0.url == nil }.map(\.id)
        XCTAssertTrue(
            missing.isEmpty,
            """
            サンプル動画がバンドルに入っていない: \(missing)
            Resources/SampleVideos/*.mp4 が Copy Bundle Resources に含まれているか確認すること。
            アプリ上ではエラーにならず、コンテンツ選択からサンプル欄が消えるだけになる。
            """
        )
        XCTAssertEqual(SampleVideo.available.count, SampleVideo.all.count)
    }

    /// 空にならないこと。available が空だとセクションごと描画されない。
    func testSampleSectionIsNotEmpty() {
        XCTAssertFalse(SampleVideo.available.isEmpty,
                       "サンプルが0件だとContentPickerViewのサンプル欄が丸ごと消える")
    }

    /// idの重複が無いこと(ForEachのIdentifiableが壊れる)。
    func testSampleIDsAreUnique() {
        let ids = SampleVideo.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "SampleVideo.id が重複している: \(ids)")
    }

    /// 表示文言が空でないこと(空ボタンを出さない)。
    func testSamplesHaveTitleAndCaption() {
        for sample in SampleVideo.all {
            XCTAssertFalse(sample.title.isEmpty, "\(sample.id): titleが空")
            XCTAssertFalse(sample.caption.isEmpty, "\(sample.id): captionが空")
            XCTAssertFalse(sample.systemImage.isEmpty, "\(sample.id): systemImageが空")
        }
    }
}

final class SampleVideoAssetTests: XCTestCase {

    /// tools/make_samples.py が生成する仕様。ここを変えるならスクリプト側も変えること。
    private let expectedSize = CGSize(width: 1920, height: 1080)
    private let expectedDuration = 12.0

    /// 各サンプルが AVFoundation で開けて、映像トラックを持つこと。
    /// = 実際に再生できる形式であること。
    func testSamplesAreDecodableVideoAssets() async throws {
        for sample in SampleVideo.all {
            let url = try XCTUnwrap(sample.url, "\(sample.id): バンドルに無い")
            let asset = AVURLAsset(url: url)

            let tracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertEqual(tracks.count, 1, "\(sample.id): 映像トラックが1本でない")

            let track = try XCTUnwrap(tracks.first)
            let isPlayable = try await asset.load(.isPlayable)
            XCTAssertTrue(isPlayable, "\(sample.id): 再生不可な素材")

            // 向き補正後のサイズで見る(F-SRC-7の素材は回転メタデータ無しの想定)。
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let oriented = natural.applying(transform)
            let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            XCTAssertEqual(size.width, expectedSize.width, accuracy: 1,
                           "\(sample.id): 幅が\(expectedSize.width)でない")
            XCTAssertEqual(size.height, expectedSize.height, accuracy: 1,
                           "\(sample.id): 高さが\(expectedSize.height)でない")
            XCTAssertEqual(transform, .identity,
                           "\(sample.id): 回転メタデータが付いている。"
                           + "リアルタイム出力パスは preferredTransform を適用しないため向きが食い違う")

            let duration = try await asset.load(.duration)
            XCTAssertEqual(duration.seconds, expectedDuration, accuracy: 0.1,
                           "\(sample.id): 尺が\(expectedDuration)秒でない")
        }
    }

    /// デフォルトクロップの3面が、どれもソース内に収まること。
    /// サンプルの構図はこのクロップに合わせて作ってある(tools/make_samples.py §冒頭)。
    func testDefaultCropsAreWithinSourceBounds() {
        let preset = MappingPreset.makeDefault()
        for (surface, config) in preset.surfaces {
            let crop = config.crop
            XCTAssertGreaterThanOrEqual(crop.minX, 0, "\(surface): クロップが左にはみ出す")
            XCTAssertGreaterThanOrEqual(crop.minY, 0, "\(surface): クロップが上にはみ出す")
            XCTAssertLessThanOrEqual(crop.maxX, 1, "\(surface): クロップが右にはみ出す")
            XCTAssertLessThanOrEqual(crop.maxY, 1, "\(surface): クロップが下にはみ出す")
            XCTAssertGreaterThan(crop.width * crop.height, 0, "\(surface): クロップが面積ゼロ")
        }
    }
}
