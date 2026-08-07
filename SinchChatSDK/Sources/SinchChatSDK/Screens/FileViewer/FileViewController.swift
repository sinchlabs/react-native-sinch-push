import UIKit

class FileViewController: SinchViewController <FileViewerViewModel, FileViewerView> {
        
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.title = mainView.localizationConfiguration.navigationBarImageViewText
        mainView.webview.load(URLRequest(url: viewModel.url))
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        setNavigationBarStyle(uiConfig: mainView.uiConfig)
        
        addCloseButton()
        addShareButton()
    }
    func addShareButton() {
        let shareButton = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareButtonPressed))

        navigationItem.leftBarButtonItem = shareButton
    }
    
    @objc func shareButtonPressed() {
        
        let vc = UIActivityViewController(activityItems: [viewModel.url], applicationActivities: [])
            vc.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
            present(vc, animated: true)
        
    }
}
