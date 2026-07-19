import UIKit
import SwiftUI

/// メイン(iPad本体)シーン。SwiftUIのEditorViewをホストするだけ。
///
/// TODO(TASK EXT-1 / 担当: scenes agent):
/// - scene(_:willConnectTo:options:) で UIWindow を生成し、
///   UIHostingController(rootView: EditorView(viewModel: AppServices.shared.viewModel))
///   をrootにして makeKeyAndVisible。
/// - 投影中の画面消灯防止(N-THERM-2): sceneDidBecomeActiveで
///   UIApplication.shared.isIdleTimerDisabled = true、resignActiveでfalse。
final class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        // Stage Manager経由の windowApplication ロールも含め、UIウィンドウを持つシーンには
        // 常に同じメインUIを載せる(調査レポート§1・AppDelegateの分岐と対応)。
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
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
