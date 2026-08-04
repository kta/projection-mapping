import XCTest
import CoreImage
import CoreGraphics
import Foundation
@testable import CornerCast

// レビュー(docs/07〜09)で確定した欠陥に対する回帰テスト。
// 「直したこと」ではなく「二度と壊れないこと」を固定するのが目的なので、
// 各テストは修正前の実装で**必ず落ちる**ように書くこと。

// MARK: - 合成結果の実画素検証(2巡目 2-C1)

/// FrameComposer 系の既存テストは `result.extent == canvas` しか見ておらず、
/// これは compose が黒キャンバスを基底に composited(over:) するだけの構造から
/// **恒真に従う**。合成本体を丸ごと削除しても通ってしまうため、実画素を読む。
final class ComposePixelTests: XCTestCase {

    private let composer = FrameComposer()
    /// GPU の無いCIランナーでも動くようソフトウェアレンダラを使う
    private let context = CIContext(options: [.useSoftwareRenderer: true])

    private func render(_ image: CIImage, size: CGSize) -> [UInt8]? {
        let rect = CGRect(origin: .zero, size: size)
        guard let cg = context.createCGImage(image, from: rect) else { return nil }
        let w = Int(size.width), h = Int(size.height)
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buffer, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: rect)
        return buffer
    }

    /// (x, y) は左上原点。返すのは RGBA。
    private func pixel(_ buffer: [UInt8], _ size: CGSize, _ x: Int, _ y: Int)
        -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * Int(size.width) + x) * 4
        guard i + 3 < buffer.count else { return (0, 0, 0, 0) }
        return (Int(buffer[i]), Int(buffer[i + 1]), Int(buffer[i + 2]), Int(buffer[i + 3]))
    }

    /// 面の内側にはソース色が来て、どの面にも割り当てられていない場所は黒のまま。
    func testSurfacesArePaintedAndOutsideStaysBlack() throws {
        let canvas = CGSize(width: 160, height: 90)
        var preset = MappingPreset.makeDefault()
        // 正面壁だけを残し、キャンバス左半分に軸平行で置く
        preset.surfaces = [
            .frontWall: SurfaceConfig(
                crop: CGRect(x: 0, y: 0, width: 1, height: 1),
                quad: Quad(rect: CGRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0)))
        ]
        preset.links = []

        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let params = RenderParameters(canvasSize: canvas, preset: preset)
        let buffer = try XCTUnwrap(render(composer.compose(frame: source, params: params),
                                          size: canvas))

        let inside = pixel(buffer, canvas, 40, 45)     // 左半分の中央
        XCTAssertGreaterThan(inside.r, 200, "面の内側がソース色(赤)になっていない")
        XCTAssertLessThan(inside.g, 60)

        let outside = pixel(buffer, canvas, 120, 45)   // 右半分(面が無い)
        XCTAssertLessThan(outside.r, 30, "面の外が黒になっていない")
    }

    /// 描画順(F-WARP-3: 床 → 左壁 → 正面壁)。重なった領域は後から描く正面壁が勝つ。
    func testDrawOrderFrontWallWinsOverlap() throws {
        let canvas = CGSize(width: 160, height: 90)
        var preset = MappingPreset.makeDefault()
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        // 床と正面壁を完全に重ねる。ソースのcropを変えて色を分ける。
        preset.surfaces = [
            .floor: SurfaceConfig(crop: CGRect(x: 0, y: 0, width: 0.5, height: 1),
                                  quad: Quad(rect: full)),
            .frontWall: SurfaceConfig(crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                                      quad: Quad(rect: full)),
        ]
        preset.links = []

        // 左半分=青、右半分=緑のソース
        let left = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64))
        let right = CIImage(color: .green).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64))
        let source = right.composited(over: left)

        let params = RenderParameters(canvasSize: canvas, preset: preset)
        let buffer = try XCTUnwrap(render(composer.compose(frame: source, params: params),
                                          size: canvas))
        let p = pixel(buffer, canvas, 80, 45)
        XCTAssertGreaterThan(p.g, 150, "重複領域が正面壁(緑)になっていない — 描画順が壊れている")
        XCTAssertLessThan(p.b, 100)
    }

    /// 明るさ(F-WARP-6)が実際に画素へ効く
    func testBrightnessHalvesPixelValue() throws {
        let canvas = CGSize(width: 64, height: 64)
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)

        func luminance(brightness: Double) throws -> Int {
            var preset = MappingPreset.makeDefault()
            preset.surfaces = [
                .frontWall: SurfaceConfig(crop: full, quad: Quad(rect: full),
                                          brightness: brightness)
            ]
            preset.links = []
            let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
            let params = RenderParameters(canvasSize: canvas, preset: preset)
            let buffer = try XCTUnwrap(render(composer.compose(frame: source, params: params),
                                              size: canvas))
            return pixel(buffer, canvas, 32, 32).r
        }

        let full_ = try luminance(brightness: 1.0)
        let half = try luminance(brightness: 0.5)
        XCTAssertGreaterThan(full_, 200)
        XCTAssertLessThan(half, full_ - 40, "brightness が画素に効いていない")
    }

    /// 出力マスク(F-MASK-1)の内側は黒く落ちる
    func testMaskBlacksOutItsQuad() throws {
        let canvas = CGSize(width: 160, height: 90)
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        var preset = MappingPreset.makeDefault()
        preset.surfaces = [.frontWall: SurfaceConfig(crop: full, quad: Quad(rect: full))]
        preset.links = []
        preset.maskShapes = [
            MaskShape(quad: Quad(rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)))
        ]

        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let params = RenderParameters(canvasSize: canvas, preset: preset)
        let buffer = try XCTUnwrap(render(composer.compose(frame: source, params: params),
                                          size: canvas))
        XCTAssertLessThan(pixel(buffer, canvas, 80, 45).r, 40, "マスクの内側が遮光されていない")
        XCTAssertGreaterThan(pixel(buffer, canvas, 10, 45).r, 200, "マスクの外まで黒くなっている")
    }
}

// MARK: - メッシュ初期化の射影変換(1巡目 #5)

final class MeshInitializationTests: XCTestCase {

    /// メッシュを有効化しても投影は動かない。
    /// 4点補正の実体は射影変換なので、内部の格子点も同じ写像に乗る必要がある。
    /// 双一次補間だった頃はパースの付いた面で数%ずれていた。
    func testMeshFromQuadMatchesPerspectiveMapping() {
        let quad = Quad(topLeft: CGPoint(x: 0.36, y: 0.13),
                        topRight: CGPoint(x: 0.66, y: 0.10),
                        bottomRight: CGPoint(x: 0.67, y: 0.60),
                        bottomLeft: CGPoint(x: 0.36, y: 0.63))
        let mesh = WarpMesh.fromQuad(quad, rows: 4, cols: 4)
        let h = UnitSquareHomography(quad: quad)

        for r in 0..<4 {
            for c in 0..<4 {
                let expected = h.map(u: CGFloat(c) / 3, v: CGFloat(r) / 3)
                let actual = mesh.point(row: r, col: c)
                XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9)
                XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9)
            }
        }
    }

    /// 4隅は元のquadと厳密に一致する
    func testMeshCornersMatchQuadExactly() {
        let quad = Quad(topLeft: CGPoint(x: 0.1, y: 0.2),
                        topRight: CGPoint(x: 0.8, y: 0.15),
                        bottomRight: CGPoint(x: 0.75, y: 0.9),
                        bottomLeft: CGPoint(x: 0.05, y: 0.85))
        let m = WarpMesh.fromQuad(quad, rows: 4, cols: 4)
        XCTAssertEqual(m.point(row: 0, col: 0).x, quad.topLeft.x, accuracy: 1e-9)
        XCTAssertEqual(m.point(row: 0, col: 3).x, quad.topRight.x, accuracy: 1e-9)
        XCTAssertEqual(m.point(row: 3, col: 3).y, quad.bottomRight.y, accuracy: 1e-9)
        XCTAssertEqual(m.point(row: 3, col: 0).y, quad.bottomLeft.y, accuracy: 1e-9)
    }

    /// 退化した四角形(3点が同一)でも NaN/Inf を作らない(F-WARP-4)
    func testDegenerateQuadProducesFiniteMesh() {
        let quad = Quad(topLeft: .zero, topRight: .zero, bottomRight: .zero,
                        bottomLeft: CGPoint(x: 1, y: 1))
        let mesh = WarpMesh.fromQuad(quad, rows: 4, cols: 4)
        for p in mesh.points {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite, "退化quadで非有限値が出た: \(p)")
        }
    }
}

// MARK: - 入力の正規化(2巡目 2-A3 / 2-A4 / 2-A5)

final class SanitizeTests: XCTestCase {

    private func presetWith(_ mutate: (inout MappingPreset) -> Void) -> MappingPreset {
        var p = MappingPreset.makeDefault()
        mutate(&p)
        return p
    }

    /// gamma=0 は面を全画素最大輝度の白にする(pow(x,0)=1)。必ず有効範囲へ寄せる。
    func testGammaZeroIsClamped() {
        let p = presetWith { $0.surfaces[.frontWall]?.gamma = 0 }
        let result = p.sanitized()
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.preset.surfaces[.frontWall]?.gamma, 0.25)
    }

    /// feather>=1.0 は inset が短辺の半分を超えて面が消える
    func testFeatherIsClampedToSliderRange() {
        let p = presetWith { $0.surfaces[.frontWall]?.feather = 1.5 }
        let result = p.sanitized()
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.preset.surfaces[.frontWall]?.feather, 0.3)
    }

    /// NaN は素通ししない。通すと JSONEncoder が throw し自動保存が永久に失敗する。
    func testNonFiniteValuesAreReplaced() {
        let p = presetWith {
            $0.surfaces[.frontWall]?.brightness = .nan
            $0.surfaces[.frontWall]?.quad.topLeft = CGPoint(x: CGFloat.nan, y: CGFloat.infinity)
        }
        let result = p.sanitized()
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.preset.surfaces[.frontWall]?.brightness, 1.0)
        let tl = try? XCTUnwrap(result.preset.surfaces[.frontWall]?.quad.topLeft)
        XCTAssertTrue((tl?.x.isFinite ?? false) && (tl?.y.isFinite ?? false))
    }

    /// sanitized を通した preset は必ずエンコードできる(自動保存が死なない)
    func testSanitizedPresetIsAlwaysEncodable() throws {
        let p = presetWith {
            $0.surfaces[.floor]?.quad.bottomRight = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
            $0.volume = .infinity
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertThrowsError(try encoder.encode(p), "NaN混入時はエンコードが失敗するはず(前提の確認)")
        XCTAssertNoThrow(try encoder.encode(p.sanitized().preset))
    }

    /// 件数の上限。巨大な配列が lastUsed.json へ焼き付くと起動のたびに固まる。
    func testExtraSurfaceCountIsCapped() {
        let config = SurfaceConfig(crop: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
                                   quad: Quad(rect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2)))
        let p = presetWith {
            $0.extras = (0..<500).map { _ in ExtraSurface(config: config) }
        }
        let result = p.sanitized()
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.preset.extras.count, MappingPreset.Limits.surfaceCount)
    }

    /// 正常な値は変更されない(過剰な丸めをしない)
    func testValidPresetIsUnchanged() {
        let result = MappingPreset.makeDefault().sanitized()
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.preset.surfaces, MappingPreset.makeDefault().surfaces)
    }

    /// 未来のスキーマは読み込みを拒否する(黙って既定値で上書きしない)
    func testFutureSchemaVersionIsRejectedOnImport() throws {
        var p = MappingPreset.makeDefault()
        p.schemaVersion = MappingPreset.currentSchemaVersion + 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(p)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PresetStore(rootDirectory: root)
        XCTAssertThrowsError(try store.decodeImported(data))
    }

    /// 値域外を含むJSONは読めるが「調整した」と報告される
    func testImportReportsAdjustment() throws {
        var p = MappingPreset.makeDefault()
        p.surfaces[.leftWall]?.gamma = 99
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(p)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PresetStore(rootDirectory: root)
        let result = try store.decodeImported(data)
        XCTAssertTrue(result.adjusted)
        XCTAssertEqual(result.preset.surfaces[.leftWall]?.gamma, 4.0)
    }
}

// MARK: - 頂点リンクの推移閉包(3巡目 3-A3)

@MainActor
final class CornerLinkPropagationTests: XCTestCase {

    /// 3面が交わるコーナーは leftWall—frontWall—floor の2本の鎖でつながる。
    /// 鎖の端(leftWall側)を動かしたとき、1ホップしか回さないと floor が置き去りになる。
    func testLinkPropagatesTransitively() {
        let vm = MappingViewModel(presetStore: InMemoryPresetStore())
        // 既定の4本のうち、床コーナーに関わる2本を有効化する
        for link in vm.preset.links {
            let touchesCorner =
                (link.a.surface == .leftWall && link.a.corner == .bottomRight)
                || (link.a.surface == .frontWall && link.a.corner == .bottomLeft)
            if touchesCorner { vm.setLink(id: link.id, enabled: true) }
        }

        let target = CGPoint(x: 0.42, y: 0.61)
        vm.move(corner: .bottomRight, of: .leftWall, to: target)

        XCTAssertEqual(vm.preset.surfaces[.leftWall]?.quad.bottomRight, target)
        XCTAssertEqual(vm.preset.surfaces[.frontWall]?.quad.bottomLeft, target)
        XCTAssertEqual(vm.preset.surfaces[.floor]?.quad.topLeft, target,
                       "2ホップ先(床)が追随していない — 伝播が1ホップで止まっている")
    }

    /// 循環するリンク構成でも停止する(無限ループしない)
    func testLinkPropagationTerminatesOnCycle() {
        let vm = MappingViewModel(presetStore: InMemoryPresetStore())
        var preset = vm.preset
        let a = CornerLink.CornerRef(surface: .leftWall, corner: .topRight)
        let b = CornerLink.CornerRef(surface: .frontWall, corner: .topLeft)
        let c = CornerLink.CornerRef(surface: .floor, corner: .topLeft)
        preset.links = [
            CornerLink(a: a, b: b, enabled: true),
            CornerLink(a: b, b: c, enabled: true),
            CornerLink(a: c, b: a, enabled: true),   // 循環
        ]
        vm.preset = preset

        let target = CGPoint(x: 0.3, y: 0.3)
        vm.move(corner: .topRight, of: .leftWall, to: target)
        XCTAssertEqual(vm.preset.surfaces[.floor]?.quad.topLeft, target)
    }
}

// MARK: - 編集ロック(1巡目 #3)

@MainActor
final class EditLockTests: XCTestCase {

    /// 編集ロック中はリセット系が素通ししない
    func testEditLockBlocksResets() {
        let vm = MappingViewModel(presetStore: InMemoryPresetStore())
        vm.move(corner: .topLeft, of: .frontWall, to: CGPoint(x: 0.9, y: 0.9))
        let adjusted = vm.preset.surfaces[.frontWall]?.quad.topLeft
        vm.isEditLocked = true

        vm.resetAll()
        XCTAssertEqual(vm.preset.surfaces[.frontWall]?.quad.topLeft, adjusted,
                       "ロック中に resetAll が通ってしまった")

        vm.resetSurface(.frontWall)
        XCTAssertEqual(vm.preset.surfaces[.frontWall]?.quad.topLeft, adjusted,
                       "ロック中に resetSurface が通ってしまった")
    }

    /// 編集ロック中はリンクの切り替えも効かない
    func testEditLockBlocksLinkToggle() throws {
        let vm = MappingViewModel(presetStore: InMemoryPresetStore())
        let link = try XCTUnwrap(vm.preset.links.first)
        vm.isEditLocked = true
        vm.setLink(id: link.id, enabled: true)
        XCTAssertFalse(try XCTUnwrap(vm.preset.links.first).enabled)
    }
}

// MARK: - 微調整の単位(1巡目 #11)

@MainActor
final class NudgeUnitTests: XCTestCase {

    /// 正規化座標の x は幅比・y は高さ比なので、1px相当の単位は軸ごとに違う。
    /// 縦横とも 1/1080 だった頃は、横方向が 1080p で 1.78px 動いていた。
    func testNudgeUnitIsPerAxis() {
        let vm = MappingViewModel(presetStore: InMemoryPresetStore())
        vm.displayState = MappingViewModel.DisplayState(
            isConnected: true, resolution: CGSize(width: 3840, height: 2160), refreshRate: 60)

        let before = try? XCTUnwrap(vm.preset.surfaces[.frontWall]?.quad.topLeft)
        vm.nudge(corner: .topLeft, of: .frontWall, dx: 1, dy: 0)
        let afterX = try? XCTUnwrap(vm.preset.surfaces[.frontWall]?.quad.topLeft)
        let dx = (afterX?.x ?? 0) - (before?.x ?? 0)
        XCTAssertEqual(dx, 1.0 / 3840.0, accuracy: 1e-12, "横方向の単位が幅基準になっていない")

        vm.nudge(corner: .topLeft, of: .frontWall, dx: 0, dy: 1)
        let afterY = try? XCTUnwrap(vm.preset.surfaces[.frontWall]?.quad.topLeft)
        let dy = (afterY?.y ?? 0) - (afterX?.y ?? 0)
        XCTAssertEqual(dy, 1.0 / 2160.0, accuracy: 1e-12, "縦方向の単位が高さ基準になっていない")
    }

    /// 未接続時は1080pを仮定する
    func testNudgeUnitFallsBackTo1080p() {
        let vm = MappingViewModel(presetStore: InMemoryPresetStore())
        XCTAssertEqual(vm.nudgeUnit.width, 1.0 / 1920.0, accuracy: 1e-12)
        XCTAssertEqual(vm.nudgeUnit.height, 1.0 / 1080.0, accuracy: 1e-12)
    }
}

// MARK: - 出力モードとコンテンツ種別の整合(1巡目 #2)

@MainActor
final class ContentSelectionTests: XCTestCase {

    /// ベイク済み動画を選んだら必ずベイク再生モードになる
    func testSelectingBakedVideoSwitchesMode() {
        let vm = MappingViewModel(presetStore: InMemoryPresetStore())
        vm.selectContent(.bakedVideo(URL(fileURLWithPath: "/tmp/x.mp4")))
        XCTAssertEqual(vm.outputMode, .bakedPlayback)
    }

    /// ベイク再生モードのまま通常動画を選んだらリアルタイムへ戻る
    /// (戻らないと前の映像が投影され続ける)
    func testSelectingVideoReturnsToRealtime() {
        let vm = MappingViewModel(presetStore: InMemoryPresetStore())
        vm.selectContent(.bakedVideo(URL(fileURLWithPath: "/tmp/x.mp4")))
        vm.selectContent(.video(URL(fileURLWithPath: "/tmp/y.mp4")))
        XCTAssertEqual(vm.outputMode, .realtime)
    }
}

// MARK: - OSCパーサ(3巡目 3-A4)

final class OSCParsingTests: XCTestCase {

    private func oscString(_ s: String) -> [UInt8] {
        var bytes = Array(s.utf8)
        bytes.append(0)
        while bytes.count % 4 != 0 { bytes.append(0) }
        return bytes
    }

    private func float(_ v: Float) -> [UInt8] {
        let bits = v.bitPattern
        return [UInt8(truncatingIfNeeded: bits >> 24), UInt8(truncatingIfNeeded: bits >> 16),
                UInt8(truncatingIfNeeded: bits >> 8), UInt8(truncatingIfNeeded: bits)]
    }

    /// 素直な ",ff" は従来どおり読める
    func testParsesTwoFloats() throws {
        var bytes = oscString("/cc/corner/frontWall/tl")
        bytes += oscString(",ff")
        bytes += float(0.25) + float(0.75)
        let msg = try XCTUnwrap(OSCMessage.parse(Data(bytes)))
        XCTAssertEqual(msg.address, "/cc/corner/frontWall/tl")
        XCTAssertEqual(msg.floats, [0.25, 0.75])
    }

    /// **文字列引数を挟んでも後続のfloatが化けないこと。**
    /// 以前は未対応型タグでオフセットを進めなかったため、
    /// 文字列の中身をfloatとして読んで頂点座標が別の値になっていた。
    func testStringArgumentDoesNotCorruptFollowingFloats() throws {
        var bytes = oscString("/cc/corner/frontWall/tl")
        bytes += oscString(",sff")
        bytes += oscString("hello")
        bytes += float(0.25) + float(0.75)
        let msg = try XCTUnwrap(OSCMessage.parse(Data(bytes)))
        XCTAssertEqual(msg.floats, [0.25, 0.75],
                       "文字列引数のぶんオフセットが進んでいない")
    }

    /// 引数を持たない型タグ(T/F/N/I)はオフセットを動かさない
    func testBooleanTagsDoNotConsumeBytes() throws {
        var bytes = oscString("/cc/mode")
        bytes += oscString(",Tf")
        bytes += float(1.0)
        let msg = try XCTUnwrap(OSCMessage.parse(Data(bytes)))
        XCTAssertEqual(msg.floats, [1.0])
    }

    /// 長さの分からない型はパースを諦める(誤った値を適用しない)
    func testUnknownTypeTagIsRejected() {
        var bytes = oscString("/cc/mode")
        bytes += oscString(",Zf")
        bytes += float(1.0)
        XCTAssertNil(OSCMessage.parse(Data(bytes)))
    }
}

// MARK: - 同梱サンプルの前提(1巡目 #14 の続き)

@MainActor
final class SampleContentIntegrationTests: XCTestCase {

    /// サンプルを選ぶとリアルタイムモードの動画ソースとして扱われる
    func testSelectingSampleUsesRealtimeVideo() throws {
        let sample = try XCTUnwrap(SampleVideo.available.first)
        let url = try XCTUnwrap(sample.url)
        let vm = MappingViewModel(presetStore: InMemoryPresetStore())
        vm.selectContent(.video(url))
        XCTAssertEqual(vm.outputMode, .realtime)
        XCTAssertEqual(vm.contentSource, .video(url))
    }
}
