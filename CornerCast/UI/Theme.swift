import SwiftUI

extension Surface {
    /// 面の識別色(SwiftUI版)。値の定義は Domain の `identityRGB` が唯一の置き場。
    /// SwiftUI のシステム色(`Color.cyan` 等)を使わないこと —
    /// 投影側の純RGBと色相が数十度ずれ、同じ面が壁と画面で違う色に見える。
    static func swiftUIColor(_ surface: Surface) -> Color {
        let rgb = surface.identityRGB
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// 自由面(F-FREE-1)の識別色(SwiftUI版)
    static var extraSurfaceColor: Color {
        let rgb = Surface.extraSurfaceRGB
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// アプリ共通の配色(v1.6: 白ベースの優しいトーン)。
///
/// デザイン方針:
/// - 背景はまぶしい純白ではなく、生成りがかった温かい白。
/// - アクセントは彩度を抑えたティール。面の識別色「水色」と親和しつつ、
///   白背景上でボタン文字(白)のコントラストを保てる明度に落としてある。
/// - 投影プレビューのキャンバスだけは「プロジェクターに映る絵」そのものなので
///   黒のまま白いカードで包む(黒=出力の事実、白=UIの温かさ、と役割を分ける)。
extension Color {
    /// アプリ共通の温かい白背景
    static let ccBackground = Color(red: 0.988, green: 0.976, blue: 0.960)
    /// カード面(背景よりわずかに明るい白)
    static let ccCard = Color.white
    /// アクセント(やわらかいティール)。tintとして全画面に適用する。
    static let ccAccent = Color(red: 0.165, green: 0.55, blue: 0.55)
    /// カードの淡い縁取り
    static let ccCardBorder = Color.black.opacity(0.06)
}

/// カードに共通のやわらかい影。
extension View {
    func ccCardShadow() -> some View {
        shadow(color: .black.opacity(0.07), radius: 14, y: 4)
    }
}
