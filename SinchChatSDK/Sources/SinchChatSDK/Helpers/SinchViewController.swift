import UIKit

open class SinchViewController<T, V: SinchView>: UIViewController {

    public let viewModel: T
    public let mainView: V
    
    public init(viewModel: T, view: V) {
        self.mainView = view
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        commonInit()
    }

    public override func loadView() {
        self.view = mainView
    }

    @available(*, unavailable, message: "Use init(_:_:)")
    public required init?(coder: NSCoder) {
        fatalError()
    }

    public func commonInit() {

    }
    
    func setNavigationBarStyle(uiConfig: SinchSDKConfig.UIConfig) {
        
        let textAttributes = [ NSAttributedString.Key.foregroundColor: uiConfig.navigationBarTitleColor,
                               NSAttributedString.Key.font: UIFont.boldSystemFont(ofSize: 16)]
        
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = uiConfig.navigationBarColor
            appearance.titleTextAttributes = textAttributes
          //  appearance.shadowColor = .clear
            navigationItem.standardAppearance = appearance
            navigationItem.compactAppearance = appearance
            navigationItem.scrollEdgeAppearance = appearance
            navigationController?.navigationBar.tintColor = uiConfig.navigationBarTitleColor

    }
    func addCloseButton() {
        let closeImage = mainView.uiConfig.closeIcon
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: closeImage,
                                                           style: .plain,
                                                           target: self,
                                                           action: #selector(closeAction))
    }
    
    @objc func closeAction() {
        self.dismiss(animated: true, completion: nil)
    }
    
    func addBackButton() {
        let backImage = mainView.uiConfig.backIcon

        navigationItem.leftBarButtonItem = UIBarButtonItem(image: backImage,
                                                           style: .plain,
                                                           target: self,
                                                           action: #selector(backAction))
    }
    
    @objc func backAction() {
        self.navigationController?.popViewController(animated: true)
    }
}
