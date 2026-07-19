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
        // デザイン方針: 投影アプリは暗い部屋で使うため常時ダーク外観で統一する
        // (キャンバス/Welcomeの黒基調とForm/ツールバーの外観差をなくす)。
        window.overrideUserInterfaceStyle = .dark
        // 状態源はAppServices.shared経由で共有する(環境注入は使わない — クラッシュ事例あり)。
        let root = UIHostingController(rootView: EditorView(viewModel: AppServices.shared.viewModel))
        window.rootViewController = root
        self.window = window
        window.makeKeyAndVisible()
    }

    // 投影中の画面消灯防止(N-THERM-2)。メインシーンのアクティブ状態に連動させる。
    func sceneDidBecomeActive(_ scene: UIScene) {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func sceneWillResignActive(_ scene: UIScene) {
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
