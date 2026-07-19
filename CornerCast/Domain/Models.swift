import CoreGraphics
import Foundation

// MARK: - 座標系の規約(全モジュール共通・厳守)
//
// このアプリには3つの座標系がある。混同が最大のバグ源なので、型と命名で区別する。
//  1. UI座標      : pt、左上原点。SwiftUIビュー内のローカル座標。
//  2. 正規化座標   : 0.0-1.0、左上原点。ドメインモデル(Quad/CropRect)の保存形式。
//                   出力解像度・ビューサイズに依存しない。
//  3. CIピクセル座標: px、左下原点。Core Image / Metal レンダリング時のみ登場。
// 変換は必ず CoordinateMapper を経由する。各所で手計算しないこと。

/// 投影対象の3面。rawValueはプリセットJSONのキーとして安定させる(変更禁止)。
/// CodingKeyRepresentable準拠(SE-0320)は必須: これが無いと [Surface: SurfaceConfig] が
/// JSONで「配列」としてエンコードされ、§8スキーマ(surfacesはオブジェクト)が壊れる。
/// 自動適用ではない(後方互換のため明示準拠が必要)ことをCIのスキーマテストが実証済み。
enum Surface: String, Codable, CaseIterable, Identifiable, Sendable, CodingKeyRepresentable {
    case leftWall
    case frontWall
    case floor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftWall: "左壁"
        case .frontWall: "正面壁"
        case .floor: "床"
        }
    }

    /// 合成時の描画順(先に描いたものが下)。要件F-WARP-3: 床 → 左壁 → 正面壁。
    static let drawOrder: [Surface] = [.floor, .leftWall, .frontWall]
}

/// 射影変換先の四角形。正規化座標(左上原点)。
struct Quad: Codable, Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    enum Corner: String, Codable, CaseIterable, Identifiable, Sendable {
        case topLeft, topRight, bottomRight, bottomLeft
        var id: String { rawValue }
    }

    subscript(_ corner: Corner) -> CGPoint {
        get {
            switch corner {
            case .topLeft: topLeft
            case .topRight: topRight
            case .bottomRight: bottomRight
            case .bottomLeft: bottomLeft
            }
        }
        set {
            switch corner {
            case .topLeft: topLeft = newValue
            case .topRight: topRight = newValue
            case .bottomRight: bottomRight = newValue
            case .bottomLeft: bottomLeft = newValue
            }
        }
    }

    /// 0-1にクランプした値を返す(F-UI-1: 点はキャンバス外へ逃げない)
    static func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }

    /// 面の初期配置。canvas内の指定矩形(正規化)に軸平行に置く。
    init(rect: CGRect) {
        topLeft = CGPoint(x: rect.minX, y: rect.minY)
        topRight = CGPoint(x: rect.maxX, y: rect.minY)
        bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
    }

    init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }
}

/// 1面ぶんの設定。crop はソース動画に対する正規化矩形(左上原点)。
struct SurfaceConfig: Codable, Equatable, Sendable {
    var crop: CGRect
    var quad: Quad
    /// 1.0が等倍。CIColorControlsのbrightnessではなく「乗算ゲイン」として扱う(0.25-2.0)
    var brightness: Double = 1.0
    /// 1.0が無補正(0.25-4.0)
    var gamma: Double = 1.0
    /// エッジフェザリング量(F-WARP-7)。面の短辺に対する割合(0=無効〜0.3)。
    /// 境界を柔らかくして継ぎ目・部屋の凹凸を目立ちにくくする。
    var feather: Double = 0.0

    init(crop: CGRect, quad: Quad,
         brightness: Double = 1.0, gamma: Double = 1.0, feather: Double = 0.0) {
        self.crop = crop
        self.quad = quad
        self.brightness = brightness
        self.gamma = gamma
        self.feather = feather
    }

    // featherはv1.3追加フィールド。既存の保存済みJSONを壊さないよう
    // decodeIfPresentで読む(カスタムはinit(from:)のみ — encodeは合成のまま)。
    private enum CodingKeys: String, CodingKey {
        case crop, quad, brightness, gamma, feather
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        crop = try c.decode(CGRect.self, forKey: .crop)
        quad = try c.decode(Quad.self, forKey: .quad)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 1.0
        gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1.0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.0
    }
}

/// 自由に追加できる面(F-FREE-1)。コーナー3面(Surface)の外側に任意枚数置ける。
/// 汎用マッピングアプリの「面の追加」に相当し、柱・天井・小物への投影に使う。
/// 頂点リンク・キーボード微調整はコーナー3面専用(追加面は対象外)。
struct ExtraSurface: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String = "追加面"
    var config: SurfaceConfig
}

/// 頂点リンク(F-WARP-5): aとbの頂点は常に同一座標に保つ
struct CornerLink: Codable, Equatable, Identifiable, Sendable {
    struct CornerRef: Codable, Equatable, Sendable {
        var surface: Surface
        var corner: Quad.Corner
    }
    var id: UUID = UUID()
    var a: CornerRef
    var b: CornerRef
    var enabled: Bool
}

/// キャリブレーション一式。プリセットJSON(F-PRESET系)のルート。
/// Identifiable準拠はプリセット一覧(ForEach)用 — idプロパティで自動満足。
struct MappingPreset: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = MappingPreset.currentSchemaVersion
    var id: UUID = UUID()
    var name: String = "新しいプリセット"
    var updatedAt: Date = .distantPast
    var surfaces: [Surface: SurfaceConfig]
    var links: [CornerLink]
    var loop: Bool = true
    var volume: Double = 1.0
    /// 自由面(F-FREE-1)。v1.3追加フィールドのためOptional(旧JSONとの互換維持)。
    /// アクセスは `extras` を使うこと。
    var extraSurfaces: [ExtraSurface]?

    /// extraSurfacesの非Optionalアクセサ(空配列はnilに正規化して保存を汚さない)
    var extras: [ExtraSurface] {
        get { extraSurfaces ?? [] }
        set { extraSurfaces = newValue.isEmpty ? nil : newValue }
    }

    /// ベイク紐付け(F-BAKE-3)用: ワープ結果に影響するフィールドのみから決定的に計算する
    var calibrationFingerprint: String {
        var parts: [String] = []
        for s in Surface.allCases {
            guard let c = surfaces[s] else { continue }
            parts.append(s.rawValue)
            parts.append(Self.configFingerprint(c))
        }
        for e in extras {
            parts.append("extra:\(e.id.uuidString)")
            parts.append(Self.configFingerprint(e.config))
        }
        return parts.joined(separator: "|")
    }

    private static func configFingerprint(_ c: SurfaceConfig) -> String {
        var parts: [String] = [
            String(format: "%.6f,%.6f,%.6f,%.6f",
                   c.crop.origin.x, c.crop.origin.y, c.crop.width, c.crop.height)
        ]
        for corner in Quad.Corner.allCases {
            let p = c.quad[corner]
            parts.append(String(format: "%.6f,%.6f", p.x, p.y))
        }
        parts.append(String(format: "%.4f,%.4f,%.4f", c.brightness, c.gamma, c.feather))
        return parts.joined(separator: ",")
    }

    /// 既定プリセット: 左1/3・中央1/3を上段、下段中央を床に割り当て(F-CROP-1)
    static func makeDefault() -> MappingPreset {
        let surfaces: [Surface: SurfaceConfig] = [
            .leftWall: SurfaceConfig(
                crop: CGRect(x: 0.0, y: 0.0, width: 1.0 / 3.0, height: 0.7),
                quad: Quad(rect: CGRect(x: 0.05, y: 0.10, width: 0.28, height: 0.55))
            ),
            .frontWall: SurfaceConfig(
                crop: CGRect(x: 1.0 / 3.0, y: 0.0, width: 1.0 / 3.0, height: 0.7),
                quad: Quad(rect: CGRect(x: 0.38, y: 0.10, width: 0.28, height: 0.55))
            ),
            .floor: SurfaceConfig(
                crop: CGRect(x: 1.0 / 3.0, y: 0.7, width: 1.0 / 3.0, height: 0.3),
                quad: Quad(rect: CGRect(x: 0.38, y: 0.70, width: 0.28, height: 0.25))
            ),
        ]
        let links = [
            CornerLink(a: .init(surface: .leftWall, corner: .topRight),
                       b: .init(surface: .frontWall, corner: .topLeft), enabled: false),
            CornerLink(a: .init(surface: .leftWall, corner: .bottomRight),
                       b: .init(surface: .frontWall, corner: .bottomLeft), enabled: false),
            CornerLink(a: .init(surface: .frontWall, corner: .bottomLeft),
                       b: .init(surface: .floor, corner: .topLeft), enabled: false),
            CornerLink(a: .init(surface: .frontWall, corner: .bottomRight),
                       b: .init(surface: .floor, corner: .topRight), enabled: false),
        ]
        return MappingPreset(surfaces: surfaces, links: links)
    }
}

// MARK: - レンダラへ渡す値型スナップショット

/// 1フレーム描画に必要な全パラメータ。参照型を含めないこと(スレッド境界を安全に越えるため)。
struct RenderParameters: Equatable, Sendable {
    struct SurfaceRender: Equatable, Sendable {
        /// コーナー3面ならその種別。自由面(F-FREE-1)はnil。
        var surface: Surface?
        /// 表示名(テストパターンのラベル等に使用)
        var name: String
        var crop: CGRect      // 正規化・左上原点
        var quad: Quad        // 正規化・左上原点
        var brightness: Double
        var gamma: Double
        var feather: Double
    }
    /// 出力キャンバスのピクセルサイズ(外部ディスプレイのcurrentMode、未接続時はプレビューサイズ)
    var canvasSize: CGSize
    /// コーナー3面(Surface.drawOrder順)→ 自由面(配列順)の描画順で整列済み
    var surfaces: [SurfaceRender]

    init(canvasSize: CGSize, preset: MappingPreset) {
        self.canvasSize = canvasSize
        var list: [SurfaceRender] = Surface.drawOrder.compactMap { s in
            guard let c = preset.surfaces[s] else { return nil }
            return SurfaceRender(surface: s, name: s.displayName,
                                 crop: c.crop, quad: c.quad,
                                 brightness: c.brightness, gamma: c.gamma,
                                 feather: c.feather)
        }
        for e in preset.extras {
            list.append(SurfaceRender(surface: nil, name: e.name,
                                      crop: e.config.crop, quad: e.config.quad,
                                      brightness: e.config.brightness,
                                      gamma: e.config.gamma,
                                      feather: e.config.feather))
        }
        self.surfaces = list
    }
}
