import UIKit
import SafariServices

@MainActor
protocol InAppMessageViewDelegate: AnyObject {

    func replyToMessage(_ choice: ChoiceText)
    func closeMessage(_ message: Message)
}

@MainActor
protocol InAppMessageViewControllerDelegate: AnyObject {
    func didTapOnChoice(_ choice: ChoiceMessageType)
    func didTapOnUrl(_ url: URL)
    func didTapOnMediaUrl(_ url: URL)

}

final class InAppMessageViewController: SinchViewController<InAppMessageViewModel, InAppMessageView>, InAppMessageViewControllerDelegate {
      
    weak var delegate: InAppMessageViewDelegate?
    
    override func viewDidLoad() {
        super.viewDidLoad()
                        
        mainView.closeButton.addTarget(self, action:#selector(closeInAppAction), for: .touchUpInside)
        mainView.cancelButton.addTarget(self, action:#selector(closeInAppAction), for: .touchUpInside)

        mainView.delegate = self
        if let message = viewModel.message.body as? MessageWithText {
            mainView.textLabel.text = message.getText()
        }
    }
    
    @objc private func closeInAppAction() {
        delegate?.closeMessage(viewModel.message)
        self.dismiss(animated: true, completion: nil)
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {

        super.traitCollectionDidChange(previousTraitCollection)

        mainView.layoutTrait(traitCollection: traitCollection)
    }
    
    func didTapOnChoice(_ choice: ChoiceMessageType) {
        
        switch choice {
        case .textMessage(let message):
            delegate?.replyToMessage(message)

        case .urlMessage(let message):
            if let url = URL(string: message.url) {
                didSelectURL(url)
            }
        case .callMessage(let message):
            ChoicesHelper.callNumber(phoneNumber: message.phoneNumber)
        case .locationMessage(let message):
            let action = LocationActionHandler(mainView.localizationConfiguration)
            DispatchQueue.main.async {
                action.handleOpenLocationAction(self, title: message.text, latitude: message.latitude, longitude: message.longitude)
            }
        }
    }
    func didTapOnUrl(_ url: URL) {
        didSelectURL(url)
    }
    
    func didTapOnMediaUrl(_ url: URL) {
        
        let mediaViewController = MediaViewerController(
            viewModel: DefaultMediaViewerViewModel(url: url),
            view: .init(uiConfiguration: mainView.uiConfig, localizationConfiguration: mainView.localizationConfiguration))
        
        let mediaNavigationController = UINavigationController(rootViewController: mediaViewController)
        mediaNavigationController.modalPresentationStyle = .fullScreen
        mediaNavigationController.modalTransitionStyle = .crossDissolve
        present(mediaNavigationController, animated: true, completion: nil)
    }

    private func didSelectURL(_ url: URL) {
        // htpps is recognized as link so we need to check if link contains http or https so SFSafariViewController dont crash
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            
            present(SFSafariViewController(url: url), animated: true)
        }
    }
}
