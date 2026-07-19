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
        // TODO: EXT-1
    }
}
