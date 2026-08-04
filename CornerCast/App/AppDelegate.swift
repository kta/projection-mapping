import UIKit

/// UIKitライフサイクル採用の理由: SwiftUIのSceneライフサイクル単体では
/// 外部ディスプレイ用シーン(windowExternalDisplayNonInteractive)を宣言できない
/// (調査レポート§1で確認済み)。メイン画面はUIHostingControllerでSwiftUIをホストする。
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 永続化済みの設定に従って外部制御(F-CTRL-1)を起動する。
        // これが無いと再起動のたびに待ち受けが消え、設定画面だけが「有効」と表示され続ける。
        MainActor.assumeIsolated { AppServices.shared.applicationDidFinishLaunching() }
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        switch connectingSceneSession.role {
        case .windowExternalDisplayNonInteractive:
            let config = UISceneConfiguration(name: "External", sessionRole: connectingSceneSession.role)
            config.delegateClass = ExternalSceneDelegate.self
            return config
        default:
            // Stage Manager経由で外部ディスプレイにwindowApplicationロールのシーンが
            // 生成される経路がある(調査レポート§1)。本アプリのUIはメイン1画面のみとし、
            // どのwindowApplicationシーンにも同じUIを出す。
            let config = UISceneConfiguration(name: "Main", sessionRole: connectingSceneSession.role)
            config.delegateClass = MainSceneDelegate.self
            return config
        }
    }
}
