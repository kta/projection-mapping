import UIKit
import SwiftUI

/// メイン(iPad本体)シーン。SwiftUIのEditorViewをホストするだけ。
/// 状態共有はAppServices.shared経由(環境注入は外部シーンでクラッシュ事例があるため不使用)。
final class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        // Stage Manager経由の windowApplication ロールも含め、UIウィンドウを持つシーンには
        // 常に同じメインUIを載せる(調査レポート§1・AppDelegateの分岐と対応)。
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        // デザイン方針(v1.6): 白ベースの優しい外観で統一する。
        // 投影される絵はキャンバス内(黒)で完結させ、UI自体は明るく親しみやすくする。
        window.overrideUserInterfaceStyle = .light
        // 状態源はAppServices.shared経由で共有する(環境注入は使わない — クラッシュ事例あり)。
        let root = UIHostingController(rootView: EditorView(viewModel: AppServices.shared.viewModel))
        window.rootViewController = root
        self.window = window
        window.makeKeyAndVisible()
    }

    // 画面消灯防止(N-THERM-2)は「投影中かどうか」で決まるため
    // ExternalDisplayManager の接続/切断に紐付けてある。ここでは触らないこと。
    // シーンのアクティブ状態に紐付けると、Split View で他アプリに触れただけで
    // 抑止が外れ、投影中でも自動ロックが復活してしまう。

    // フォアグラウンド復帰時の再生・出力状態の復元(N-REL-1)
    func sceneDidEnterBackground(_ scene: UIScene) {
        AppServices.shared.playback.sceneDidEnterBackground()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        AppServices.shared.playback.sceneWillEnterForeground()
    }
}
