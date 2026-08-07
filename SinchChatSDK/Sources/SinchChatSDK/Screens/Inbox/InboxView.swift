import UIKit

final class InboxView: SinchView {
    
    var tableView: UITableView
    let errorView = ErrorView()
    var errorViewTopConstraint: NSLayoutConstraint?
    
    override init(uiConfiguration: SinchSDKConfig.UIConfig, localizationConfiguration: SinchSDKConfig.LocalizationConfig) {
        
        tableView = UITableView()
        tableView.register(InboxTableViewCell.self, forCellReuseIdentifier: "inboxCell")
        
        super.init(uiConfiguration: uiConfiguration, localizationConfiguration: localizationConfiguration)
        
    }
    
    override func setupSubviews() {
        backgroundColor = uiConfig.inboxBackgroundColor
        addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(errorView)
        errorView.translatesAutoresizingMaskIntoConstraints = false
        errorView.isHidden = true
        
    }
    override func setupConstraints() {
        
        errorViewTopConstraint = errorView.topAnchor.constraint(equalTo:  self.safeAreaLayoutGuide.topAnchor, constant: -40)
        errorViewTopConstraint?.isActive = true
        errorView.bottomAnchor.constraint(equalTo: tableView.topAnchor).isActive = true
        errorView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor).isActive = true
        errorView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor).isActive = true
        errorView.heightAnchor.constraint(equalToConstant: 40).isActive = true
        
        tableView.topAnchor.constraint(equalTo: errorView.bottomAnchor).isActive = true
        tableView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor).isActive = true
        tableView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor).isActive = true
        tableView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor).isActive = true
    }
    
    func setErrorViewState(_ state: InternetConnectionState) {
        
        switch state {
        case .isOn:
            errorView.updateToState(.isInternetOn)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.errorViewTopConstraint?.constant = -40
                UIView.animate(withDuration: 0.6, animations: {
                    self.layoutIfNeeded()
                    
                }, completion: { _ in
                    self.errorView.isHidden = true
                    
                })
            }
        case .isOff:
            errorView.isHidden = false
            errorView.updateToState(.isInternetOff)
            errorViewTopConstraint?.constant = 0
            UIView.animate(withDuration: 0.6, animations: {
                self.layoutIfNeeded()
                
            })
        case .notDetermined:
            break
        }
    }
}
