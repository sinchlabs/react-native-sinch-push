import QuickLook

class PreviewViewController: QLPreviewController {
    
    public var uiConfig = SinchSDKConfig.UIConfig.defaultValue
    public var localizationConfiguration = SinchSDKConfig.LocalizationConfig.defaultValue
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let textAttributes = [ NSAttributedString.Key.foregroundColor: uiConfig.navigationBarTitleColor,
                               NSAttributedString.Key.font: UIFont.boldSystemFont(ofSize: 16)]
        
        if #available(iOS 13.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = uiConfig.navigationBarColor
            appearance.titleTextAttributes = textAttributes
            
            navigationItem.standardAppearance = appearance
            navigationItem.scrollEdgeAppearance = appearance
            navigationController?.navigationBar.tintColor = uiConfig.navigationBarTitleColor
            
        } else {
            navigationController?.navigationBar.barTintColor = uiConfig.navigationBarColor
            navigationController?.navigationBar.tintColor = uiConfig.navigationBarTitleColor
            navigationController?.navigationBar.titleTextAttributes = textAttributes
        }
    }
}
