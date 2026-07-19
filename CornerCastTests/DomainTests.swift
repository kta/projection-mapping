import XCTest
import CoreGraphics
@testable import CornerCast

// TEST-1: ドメイン層(Models / CoordinateMapper)のユニットテスト。
// 実装済みコードの「現在の仕様」を固定する目的で書く。
// ViewModel は ViewModelTests.swift、FrameComposer は FrameComposerTests.swift に分割。

// MARK: - CoordinateMapper

final class CoordinateMapperTests: XCTestCase {

    /// normalized(fromUI:) ⇔ ui(fromNormalized:) のラウンドトリップ
    func testUINormalizedRoundTrip() {
        let viewSize = CGSize(width: 400, height: 300)
        let uiPoint = CGPoint(x: 100, y: 150)

        let norm = CoordinateMapper.normalized(fromUI: uiPoint, in: viewSize)
        XCTAssertEqual(norm.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(norm.y, 0.5, accuracy: 1e-9)

        let back = CoordinateMapper.ui(fromNormalized: norm, in: viewSize)
        XCTAssertEqual(back.x, uiPoint.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, uiPoint.y, accuracy: 1e-9)
    }

    /// viewSize が 0 のとき normalized は .zero を返す(ゼロ除算ガード)
    func testNormalizedGuardsZeroViewSize() {
        let n = CoordinateMapper.normalized(fromUI: CGPoint(x: 10, y: 10),
                                            in: CGSize(width: 0, height: 0))
        XCTAssertEqual(n, .zero)
    }

    /// ciPixel: (0,0)左上 → (0, H)、(1,1)右下 → (W, 0)(Y反転の検証)
    func testCIPixelFlipsY() {
        let canvas = CGSize(width: 1920, height: 1080)

        let topLeft = CoordinateMapper.ciPixel(fromNormalized: CGPoint(x: 0, y: 0), canvasSize: canvas)
        XCTAssertEqual(topLeft.x, 0, accuracy: 1e-6)
        XCTAssertEqual(topLeft.y, 1080, accuracy: 1e-6)

        let bottomRight = CoordinateMapper.ciPixel(fromNormalized: CGPoint(x: 1, y: 1), canvasSize: canvas)
        XCTAssertEqual(bottomRight.x, 1920, accuracy: 1e-6)
        XCTAssertEqual(bottomRight.y, 0, accuracy: 1e-6)

        // 中央は中央のまま
        let center = CoordinateMapper.ciPixel(fromNormalized: CGPoint(x: 0.5, y: 0.5), canvasSize: canvas)
        XCTAssertEqual(center.x, 960, accuracy: 1e-6)
        XCTAssertEqual(center.y, 540, accuracy: 1e-6)
    }

    /// ciRect: 正規化(0,0,0.5,0.5)=「左上1/4」が extent の左上1/4
    /// (CIでは左下原点なので、xは左半分・yは上半分= y∈[H/2, H])に写ること
    func testCIRectMapsTopLeftQuarter() {
        let extent = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let r = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)

        let ci = CoordinateMapper.ciRect(fromNormalized: r, in: extent)
        XCTAssertEqual(ci.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(ci.width, 960, accuracy: 1e-6)
        XCTAssertEqual(ci.height, 540, accuracy: 1e-6)
        // 「左上1/4」はCI座標では上半分 → y は H/2 から H まで
        XCTAssertEqual(ci.minY, 540, accuracy: 1e-6)
        XCTAssertEqual(ci.maxY, 1080, accuracy: 1e-6)
    }

    /// ciRect: 原点が (0,0) でない extent でもオフセットを考慮する
    func testCIRectHonorsExtentOrigin() {
        let extent = CGRect(x: 100, y: 200, width: 400, height: 300)
        // 全体(0,0,1,1)を渡すと extent そのものに一致する
        let ci = CoordinateMapper.ciRect(fromNormalized: CGRect(x: 0, y: 0, width: 1, height: 1), in: extent)
        XCTAssertEqual(ci.minX, extent.minX, accuracy: 1e-6)
        XCTAssertEqual(ci.minY, extent.minY, accuracy: 1e-6)
        XCTAssertEqual(ci.width, extent.width, accuracy: 1e-6)
        XCTAssertEqual(ci.height, extent.height, accuracy: 1e-6)
    }
}

// MARK: - Quad

final class QuadTests: XCTestCase {

    /// clamped: 範囲外座標が 0-1 に収まる
    func testClampedClipsOutOfRange() {
        XCTAssertEqual(Quad.clamped(CGPoint(x: -0.5, y: -2.0)), CGPoint(x: 0, y: 0))
        XCTAssertEqual(Quad.clamped(CGPoint(x: 1.5, y: 3.0)), CGPoint(x: 1, y: 1))
        // 範囲内はそのまま
        XCTAssertEqual(Quad.clamped(CGPoint(x: 0.3, y: 0.7)), CGPoint(x: 0.3, y: 0.7))
    }

    /// init(rect:) が軸平行に4隅を置く
    func testInitFromRect() {
        let q = Quad(rect: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5))
        XCTAssertEqual(q.topLeft, CGPoint(x: 0.1, y: 0.2))
        XCTAssertEqual(q.topRight, CGPoint(x: 0.5, y: 0.2))
        XCTAssertEqual(q.bottomRight, CGPoint(x: 0.5, y: 0.7))
        XCTAssertEqual(q.bottomLeft, CGPoint(x: 0.1, y: 0.7))
    }

    /// subscript get/set が全 Corner を正しく読み書きする
    func testSubscriptGetSetAllCorners() {
        var q = Quad(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        for (i, corner) in Quad.Corner.allCases.enumerated() {
            let p = CGPoint(x: Double(i) * 0.1, y: Double(i) * 0.2)
            q[corner] = p
            XCTAssertEqual(q[corner], p, "corner \(corner.rawValue) の set/get が一致しない")
        }
        // 個別フィールドとの対応も確認
        XCTAssertEqual(q[.topLeft], q.topLeft)
        XCTAssertEqual(q[.topRight], q.topRight)
        XCTAssertEqual(q[.bottomRight], q.bottomRight)
        XCTAssertEqual(q[.bottomLeft], q.bottomLeft)
    }
}

// MARK: - MappingPreset

final class MappingPresetTests: XCTestCase {

    /// makeDefault: 3面すべて存在、links 4本
    func testMakeDefaultShape() {
        let p = MappingPreset.makeDefault()
        XCTAssertEqual(p.surfaces.count, 3)
        for s in Surface.allCases {
            XCTAssertNotNil(p.surfaces[s], "面 \(s.rawValue) が存在しない")
        }
        XCTAssertEqual(p.links.count, 4)
        XCTAssertTrue(p.links.allSatisfy { $0.enabled == false }, "既定リンクは全て無効のはず")
        XCTAssertEqual(p.schemaVersion, MappingPreset.currentSchemaVersion)
    }

    /// calibrationFingerprint: quad を動かすと変化する
    func testFingerprintChangesOnQuadMove() {
        let base = MappingPreset.makeDefault()
        var moved = base
        moved.surfaces[.frontWall]?.quad.topLeft = CGPoint(x: 0.9, y: 0.9)
        XCTAssertNotEqual(base.calibrationFingerprint, moved.calibrationFingerprint)
    }

    /// calibrationFingerprint: crop / brightness / gamma でも変化する
    func testFingerprintChangesOnColorAndCrop() {
        let base = MappingPreset.makeDefault()

        var b = base
        b.surfaces[.frontWall]?.brightness = 1.5
        XCTAssertNotEqual(base.calibrationFingerprint, b.calibrationFingerprint)

        var g = base
        g.surfaces[.frontWall]?.gamma = 2.0
        XCTAssertNotEqual(base.calibrationFingerprint, g.calibrationFingerprint)

        var c = base
        c.surfaces[.frontWall]?.crop = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        XCTAssertNotEqual(base.calibrationFingerprint, c.calibrationFingerprint)
    }

    /// calibrationFingerprint: name / updatedAt の変更では不変
    func testFingerprintStableOnMetadata() {
        let base = MappingPreset.makeDefault()
        var meta = base
        meta.name = "別名プリセット"
        meta.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        meta.loop = false
        meta.volume = 0.3
        XCTAssertEqual(base.calibrationFingerprint, meta.calibrationFingerprint)
    }

    /// Codable ラウンドトリップ(JSONEncoder → Decoder で等価)
    func testCodableRoundTrip() throws {
        let original = MappingPreset.makeDefault()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MappingPreset.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(original.calibrationFingerprint, decoded.calibrationFingerprint)
    }
}
