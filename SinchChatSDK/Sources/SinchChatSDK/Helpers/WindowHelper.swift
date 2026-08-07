import UIKit

public final class WindowHelper {
   
    public static func getVisibleController() -> UIViewController? {
        if #available(iOS 13.0, *) {
            
            var windowScene: UIWindowScene?
            var activeWindowScene: UIWindowScene?
            
            for scene in UIApplication.shared.connectedScenes {
                if let scene = scene as? UIWindowScene {
                    
                    windowScene = scene
                    
                    if scene.activationState == .foregroundActive {
                        activeWindowScene = windowScene
                        break
                    }
                }
            }
            
            let activeWindow = activeWindowScene ?? windowScene
            if let delegate = activeWindow?.delegate as? UIWindowSceneDelegate, let window = delegate.window, let viewController =  window?.rootViewController {
                return  getVisibleViewController(viewController)
            }
        }
        
        return getVisibleViewController(UIApplication.shared.delegate?.window??.rootViewController )
        
    }
    
    public static func getVisibleViewController(_ currentVc: UIViewController?) -> UIViewController? {
        
        if let presentedViewController = currentVc?.presentedViewController {
            return getVisibleViewController(presentedViewController)
        }
        
        if let navigationController = currentVc as? UINavigationController {
            return navigationController.visibleViewController
        }
        
        if let tabBarController = currentVc as? UITabBarController {
            return tabBarController.selectedViewController
        }
        
        if let pageViewController = currentVc as? UIPageViewController {
            return pageViewController
        }
        if let alert = currentVc as? UIAlertController {
            return alert
        }
        
        return currentVc
    }
}
