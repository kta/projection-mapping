import Foundation

/// アプリに同梱するサンプル動画(F-SRC-7)。
///
/// 自分の動画を用意しなくても、コンテンツ選択からワンタップで投影を試せる。
/// 実体は Resources/SampleVideos/*.mp4(tools/make_samples.py で生成した
/// 1920x1080 / 12秒のシームレスループ。構図はデフォルトクロップ F-CROP-1 に一致)。
struct SampleVideo: Identifiable {
    /// バンドル内のリソース名(拡張子なし)
    let id: String
    let title: String
    let caption: String
    let systemImage: String

    var url: URL? {
        Bundle.main.url(forResource: id, withExtension: "mp4")
    }

    static let all: [SampleVideo] = [
        SampleVideo(id: "warp-drive",
                    title: "ワープ航行",
                    caption: "星のあいだを走りぬける、SFコックピット体験",
                    systemImage: "sparkles"),
        SampleVideo(id: "gentle-ocean",
                    title: "夕なぎの海",
                    caption: "夕暮れの空と海。床には、ゆらめく水面",
                    systemImage: "water.waves"),
        SampleVideo(id: "firefly-forest",
                    title: "ホタルの森",
                    caption: "夜の森にホタルの光がただよう、癒しの時間",
                    systemImage: "moon.stars"),
    ]

    /// バンドルに実在するものだけ(リソース欠落時に空ボタンを出さない)
    static var available: [SampleVideo] {
        all.filter { $0.url != nil }
    }
}
