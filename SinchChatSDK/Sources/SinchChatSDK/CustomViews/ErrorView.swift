import UIKit

enum InternetConnectionState {
    case isOn
    case isOff
    case notDetermined
}

final class ErrorView: SinchView {
    
    var textLabel: UILabel = UILabel()
    var imageView: UIImageView = UIImageView()
    var stackView: UIStackView = UIStackView()

    override func setupSubviews() {
        
        imageView.contentMode = .scaleAspectFit
        imageView.image = UIImage(named: "connectedIcon", in: Bundle.staticBundle, compatibleWith: nil)
        textLabel.textAlignment = .left
        
        textLabel.textColor = .white
        textLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        stackView.addArrangedSubview(imageView)
        stackView.addArrangedSubview(textLabel)
      
        stackView.distribution = .fillProportionally
        stackView.alignment = .center
        stackView.axis = .horizontal
        stackView.spacing = 10
        addSubview(stackView)
      
        stackView.translatesAutoresizingMaskIntoConstraints = false
     
    }
    override func setupConstraints() {
    
        let stackViewHeight = stackView.heightAnchor.constraint(equalToConstant: 20)
        let stackViewXCenter = stackView.centerXAnchor.constraint(equalTo: centerXAnchor)
        let stackViewYCenter = stackView.centerYAnchor.constraint(equalTo: centerYAnchor)

        NSLayoutConstraint.activate([stackViewHeight, stackViewXCenter, stackViewYCenter])

    }
    func updateToState(_ state: ChatErrorState) {

        switch state {
        case .isInternetOn:
            textLabel.text = localizationConfiguration.connected
            imageView.image = UIImage(named: "connectedIcon", in: Bundle.staticBundle, compatibleWith: nil)
            backgroundColor = UIColor(named: "connectedColor", in: Bundle.staticBundle, compatibleWith: nil)
        case .isInternetOff:
            textLabel.text = localizationConfiguration.noInternetConnection
            imageView.image = UIImage(named: "disconnectedIcon", in: Bundle.staticBundle, compatibleWith: nil)
            backgroundColor = UIColor(named: "primaryRedColor", in: Bundle.staticBundle, compatibleWith: nil)

        case .none:
            break
        case .agentNotInChat:
            textLabel.text = localizationConfiguration.agentHasNotJoined
            imageView.image = UIImage(named: "disconnectedIcon", in: Bundle.staticBundle, compatibleWith: nil)
            backgroundColor = UIColor(named: "primaryRedColor", in: Bundle.staticBundle, compatibleWith: nil)
            
        case .agentInChat:
            textLabel.text = localizationConfiguration.agentHasJoined
            imageView.image = UIImage(named: "connectedIcon", in: Bundle.staticBundle, compatibleWith: nil)
            backgroundColor = UIColor(named: "connectedColor", in: Bundle.staticBundle, compatibleWith: nil)
        }
        
        layoutIfNeeded()
    }
    
}
