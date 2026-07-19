import XCTest
import CoreImage
import CoreGraphics
@testable import CornerCast

// TEST-1: FrameComposer のユニットテスト。
// CIImage のピクセル値検証は CIContext レンダリングが必要でシミュレータ依存のため、
// extent 検証と「レシピ構築がクラッシュしないこと」の確認までに留める。

final class FrameComposerTests: XCTestCase {

    private let composer = FrameComposer()

    /// 有限 extent を持つソースフレームを作る
    private func makeFrame(width: CGFloat = 1280, height: CGFloat = 720) -> CIImage {
        CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// compose 結果の extent が (0,0,canvasSize) に一致する
    func testComposeExtentMatchesCanvas() {
        let canvas = CGSize(width: 1920, height: 1080)
        let params = RenderParameters(canvasSize: canvas, preset: .makeDefault())
        let result = composer.compose(frame: makeFrame(), params: params)
        XCTAssertEqual(result.extent, CGRect(origin: .zero, size: canvas))
    }

    /// 非正方・非1920 のキャンバスでも extent がキャンバスに一致する
    func testComposeExtentMatchesArbitraryCanvas() {
        let canvas = CGSize(width: 1024, height: 768)
        let params = RenderParameters(canvasSize: canvas, preset: .makeDefault())
        let result = composer.compose(frame: makeFrame(width: 640, height: 480), params: params)
        XCTAssertEqual(result.extent, CGRect(origin: .zero, size: canvas))
    }

    /// surfaces が空でも黒キャンバスが返る(クラッシュしない)
    func testComposeWithNoSurfacesReturnsBlackCanvas() {
        let canvas = CGSize(width: 1920, height: 1080)
        let emptyPreset = MappingPreset(surfaces: [:], links: [])
        let params = RenderParameters(canvasSize: canvas, preset: emptyPreset)
        XCTAssertTrue(params.surfaces.isEmpty)

        let result = composer.compose(frame: makeFrame(), params: params)
        XCTAssertEqual(result.extent, CGRect(origin: .zero, size: canvas))
    }

    /// 色補正あり(brightness/gamma が既定以外)でもレシピ構築でクラッシュしない
    func testComposeWithColorAdjustmentsDoesNotCrash() {
        let canvas = CGSize(width: 1920, height: 1080)
        var preset = MappingPreset.makeDefault()
        preset.surfaces[.frontWall]?.brightness = 1.6
        preset.surfaces[.frontWall]?.gamma = 2.2
        let params = RenderParameters(canvasSize: canvas, preset: preset)

        let result = composer.compose(frame: makeFrame(), params: params)
        XCTAssertEqual(result.extent, CGRect(origin: .zero, size: canvas))
    }

    /// RenderParameters が Surface.drawOrder(床→左壁→正面壁)順に整列される
    func testRenderParametersOrderedByDrawOrder() {
        let params = RenderParameters(canvasSize: CGSize(width: 1920, height: 1080),
                                      preset: .makeDefault())
        XCTAssertEqual(params.surfaces.map { $0.surface }, Surface.drawOrder)
    }
}
