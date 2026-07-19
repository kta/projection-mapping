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

/// メッシュワープ(F-MESH-1): 4点補正の上位互換。rows×colsの制御点グリッドで
/// 面を細分化し、部屋の凹凸・レンズ歪みに追従させる。座標は正規化キャンバス(左上原点)。
struct WarpMesh: Codable, Equatable, Sendable {
    var rows: Int          // 制御点の行数(セル数はrows-1)
    var cols: Int
    /// row-major順。count == rows * cols
    var points: [CGPoint]

    func point(row: Int, col: Int) -> CGPoint { points[row * cols + col] }
    func index(row: Int, col: Int) -> Int { row * cols + col }

    /// 既存の4点quadから双一次補間でメッシュを初期化する(有効化時の初期状態)
    static func fromQuad(_ q: Quad, rows: Int = 4, cols: Int = 4) -> WarpMesh {
        var pts: [CGPoint] = []
        pts.reserveCapacity(rows * cols)
        for r in 0..<rows {
            let v = CGFloat(r) / CGFloat(rows - 1)
            let left = Self.lerp(q.topLeft, q.bottomLeft, v)
            let right = Self.lerp(q.topRight, q.bottomRight, v)
            for c in 0..<cols {
                let u = CGFloat(c) / CGFloat(cols - 1)
                pts.append(Self.lerp(left, right, u))
            }
        }
        return WarpMesh(rows: rows, cols: cols, points: pts)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

/// 出力マスク(F-MASK-1): 最終合成の上に重ねる黒い四角形。
/// ドア枠・窓・家具など「光を当てたくない場所」を遮る。
struct MaskShape: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String = "マスク"
    var quad: Quad
}

/// 出力エフェクト(F-FX-1): ソース映像全体への色調整。ベイクにも焼き込まれる。
struct EffectSettings: Codable, Equatable, Sendable {
    var saturation: Double = 1.0   // 0-2
    var contrast: Double = 1.0     // 0.5-1.5
    var brightness: Double = 0.0   // -0.5-0.5(加算)
    var hueDegrees: Double = 0.0   // -180-180

    var isNeutral: Bool {
        saturation == 1.0 && contrast == 1.0 && brightness == 0.0 && hueDegrees == 0.0
    }
    static let neutral = EffectSettings()
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
    var feather: Double = 0.0
    /// メッシュワープ(F-MESH-1)。nil=通常の4点補正。非nil時はquadの代わりにメッシュで変形する。
    var mesh: WarpMesh?

    init(crop: CGRect, quad: Quad,
         brightness: Double = 1.0, gamma: Double = 1.0, feather: Double = 0.0,
         mesh: WarpMesh? = nil) {
        self.crop = crop
        self.quad = quad
        self.brightness = brightness
        self.gamma = gamma
        self.feather = feather
        self.mesh = mesh
    }

    // feather/meshは後付けフィールド。既存の保存済みJSONを壊さないよう
    // decodeIfPresentで読む(カスタムはinit(from:)のみ — encodeは合成のまま)。
    private enum CodingKeys: String, CodingKey {
        case crop, quad, brightness, gamma, feather, mesh
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        crop = try c.decode(CGRect.self, forKey: .crop)
        quad = try c.decode(Quad.self, forKey: .quad)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 1.0
        gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1.0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.0
        mesh = try c.decodeIfPresent(WarpMesh.self, forKey: .mesh)
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
    /// 出力マスク(F-MASK-1)。v1.4追加・Optional互換。アクセスは `maskShapes`。
    var masks: [MaskShape]?
    /// 出力エフェクト(F-FX-1)。v1.4追加・Optional互換。アクセスは `effectSettings`。
    var effects: EffectSettings?

    /// extraSurfacesの非Optionalアクセサ(空配列はnilに正規化して保存を汚さない)
    var extras: [ExtraSurface] {
        get { extraSurfaces ?? [] }
        set { extraSurfaces = newValue.isEmpty ? nil : newValue }
    }

    var maskShapes: [MaskShape] {
        get { masks ?? [] }
        set { masks = newValue.isEmpty ? nil : newValue }
    }

    var effectSettings: EffectSettings {
        get { effects ?? .neutral }
        set { effects = newValue.isNeutral ? nil : newValue }
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
        for m in maskShapes {
            parts.append("mask:\(m.id.uuidString)")
            for corner in Quad.Corner.allCases {
                let p = m.quad[corner]
                parts.append(String(format: "%.6f,%.6f", p.x, p.y))
            }
        }
        let fx = effectSettings
        if !fx.isNeutral {
            parts.append(String(format: "fx:%.4f,%.4f,%.4f,%.4f",
                                fx.saturation, fx.contrast, fx.brightness, fx.hueDegrees))
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
        if let mesh = c.mesh {
            parts.append("mesh\(mesh.rows)x\(mesh.cols):"
                + mesh.points.map { String(format: "%.6f,%.6f", $0.x, $0.y) }.joined(separator: ";"))
        }
        return parts.joined(separator: ",")
    }

    /// プロジェクトテンプレート(F-TPL-1): 起動時のユースケース選択
    enum ProjectTemplate: String, CaseIterable, Identifiable {
        case cornerCockpit   // 3面コーナー(本アプリの主用途)
        case freeform        // もっと自由に(コーナー面なし・自由面のみ)
        case sample          // サンプル(調整済みデモ+テストパターン)

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .cornerCockpit: return "3面コーナー"
            case .freeform: return "もっと自由に"
            case .sample: return "サンプル"
            }
        }

        var caption: String {
            switch self {
            case .cornerCockpit:
                return "左壁・正面壁・床のコーナーに投影する定番構成。頂点リンクで継ぎ目もぴったり。"
            case .freeform:
                return "白紙から始めて、面を好きな数だけ追加。柱・天井・オブジェクトへの汎用マッピング。"
            case .sample:
                return "調整済みのデモ構成をテストパターン付きで表示。まず動きを見たい人向け。"
            }
        }

        var systemImage: String {
            switch self {
            case .cornerCockpit: return "cube"
            case .freeform: return "square.on.square.dashed"
            case .sample: return "sparkles.tv"
            }
        }
    }

    /// テンプレートからプリセットを生成する
    static func make(template: ProjectTemplate) -> MappingPreset {
        switch template {
        case .cornerCockpit:
            var p = makeDefault()
            p.name = "3面コーナー"
            return p
        case .freeform:
            var p = MappingPreset(surfaces: [:], links: [])
            p.name = "フリーマッピング"
            let config = SurfaceConfig(
                crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                quad: Quad(rect: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)))
            p.extras = [ExtraSurface(name: "面1", config: config)]
            return p
        case .sample:
            var p = makeDefault()
            p.name = "サンプル"
            // デモらしく少しパースの付いた配置にする(実投影の雰囲気を見せる)
            p.surfaces[.leftWall]?.quad = Quad(
                topLeft: CGPoint(x: 0.04, y: 0.08),
                topRight: CGPoint(x: 0.34, y: 0.14),
                bottomRight: CGPoint(x: 0.34, y: 0.62),
                bottomLeft: CGPoint(x: 0.04, y: 0.80))
            p.surfaces[.frontWall]?.quad = Quad(
                topLeft: CGPoint(x: 0.36, y: 0.13),
                topRight: CGPoint(x: 0.66, y: 0.10),
                bottomRight: CGPoint(x: 0.67, y: 0.60),
                bottomLeft: CGPoint(x: 0.36, y: 0.63))
            p.surfaces[.floor]?.quad = Quad(
                topLeft: CGPoint(x: 0.37, y: 0.66),
                topRight: CGPoint(x: 0.67, y: 0.63),
                bottomRight: CGPoint(x: 0.78, y: 0.92),
                bottomLeft: CGPoint(x: 0.30, y: 0.95))
            return p
        }
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
        /// メッシュワープ(F-MESH-1)。非nil時はquadの代わりに使う。
        var mesh: WarpMesh?
    }
    /// 出力キャンバスのピクセルサイズ(外部ディスプレイのcurrentMode、未接続時はプレビューサイズ)
    var canvasSize: CGSize
    /// コーナー3面(Surface.drawOrder順)→ 自由面(配列順)の描画順で整列済み
    var surfaces: [SurfaceRender]
    /// 出力マスク(F-MASK-1)。全面の合成後に黒で重ねる。
    var maskQuads: [Quad]
    /// 出力エフェクト(F-FX-1)。ソース映像に分割前へ適用する。
    var effects: EffectSettings

    init(canvasSize: CGSize, preset: MappingPreset) {
        self.canvasSize = canvasSize
        var list: [SurfaceRender] = Surface.drawOrder.compactMap { s in
            guard let c = preset.surfaces[s] else { return nil }
            return SurfaceRender(surface: s, name: s.displayName,
                                 crop: c.crop, quad: c.quad,
                                 brightness: c.brightness, gamma: c.gamma,
                                 feather: c.feather, mesh: c.mesh)
        }
        for e in preset.extras {
            list.append(SurfaceRender(surface: nil, name: e.name,
                                      crop: e.config.crop, quad: e.config.quad,
                                      brightness: e.config.brightness,
                                      gamma: e.config.gamma,
                                      feather: e.config.feather,
                                      mesh: e.config.mesh))
        }
        self.surfaces = list
        self.maskQuads = preset.maskShapes.map(\.quad)
        self.effects = preset.effectSettings
    }
}
