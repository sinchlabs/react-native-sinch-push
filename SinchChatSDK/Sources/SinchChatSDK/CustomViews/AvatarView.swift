import UIKit

final class AvatarView: UIView {
    
    var nameLabel: UILabel = UILabel()
    var imageView: UIImageView = UIImageView()
    
    override var frame: CGRect {
        didSet {
            setSubviews()
            setCorner()
        }
    }

    override var bounds: CGRect {
        didSet {
            setSubviews()
            setCorner()
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        prepareView()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        prepareView()
    }

    convenience public init() {
        self.init(frame: .zero)
        prepareView()
    }

    func prepareView() {
        layer.masksToBounds = true
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFit
        nameLabel.textAlignment = .center
        addSubview(imageView)
        addSubview(nameLabel)
        setCorner()
        setSubviews()
    }

    func setCorner() {
            
        let cornerRadius = min(frame.width, frame.height)
        layer.cornerRadius = cornerRadius/2
        
    }
    func setSubviews() {
            
        imageView.frame = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        nameLabel.frame = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)

    }

    func updateWithChannel(_ channel: Sinch_Chat_Sdk_V1alpha2_Channel, uiConfig: SinchSDKConfig.UIConfig) {
        var name: String?
        var pictureUrlString: String?
        
        if channel.hasLastEntry, let message = handleIncomingMessage(channel.lastEntry) {
            
            switch message.owner {
            case .incoming(let agent):
                if let agent = agent {
                    name = agent.name
                    pictureUrlString = agent.pictureUrl
                }
                
            case .outgoing:
                //TODO
                break
            case .system:
                break
            }
            
            nameLabel.text = ""
            nameLabel.textColor = uiConfig.inboxAvatarNameTextColor
            backgroundColor = uiConfig.inboxAvatarBackgroundColor
            
            if let imageUrl = pictureUrlString,
               let imageURL = URL(string: imageUrl) {
                
                imageView.setImage(url: imageURL) { result in
                    switch result {
                    case .success:
                        self.nameLabel.isHidden = true
                        self.imageView.isHidden = false
                        
                        self.backgroundColor = uiConfig.incomingMessageSenderBackgroundColor
                    case .failure:
                        self.handleNonAvatarModelsWithName(name, uiConfig: uiConfig)
                    }
                }
                
            } else {
                handleNonAvatarModelsWithName(name, uiConfig: uiConfig)
            }
        }
    }
    func updateWithModel(_ message: Message, uiConfig: SinchSDKConfig.UIConfig) {
        nameLabel.font = uiConfig.incomingMessageSenderNameFont
        nameLabel.textColor = uiConfig.incomingMessageSenderNameTextColor
        imageView.image = uiConfig.chatBotImage
        imageView.backgroundColor = uiConfig.incomingMessageChatbotBackgroundColor
        
        if case let .incoming(agent) = message.owner {
            
            if let imageUrl = agent?.pictureUrl,
               let imageURL = URL(string: imageUrl) {
                
                imageView.setImage(url: imageURL) { result in
                    switch result {
                    case .success:
                        self.nameLabel.isHidden = true
                        self.imageView.isHidden = false
                        
                        self.backgroundColor = uiConfig.incomingMessageSenderBackgroundColor
                    case .failure:
                        self.handleNonAvatarModels(agent, uiConfig: uiConfig)
                    }
                }
                
            } else {
                handleNonAvatarModels(agent, uiConfig: uiConfig)
            }
        }
    }
    private func handleNonAvatarModelsWithName(_ name: String?, uiConfig: SinchSDKConfig.UIConfig) {
            
        if let name = name {
            
            if let firstLetter = name.first?.uppercased() {
                nameLabel.text = firstLetter
            }
            nameLabel.isHidden = false
            imageView.isHidden = true
            backgroundColor = uiConfig.inboxAvatarBackgroundColor
            
        } else {
            nameLabel.text = ""
            nameLabel.isHidden = true
            imageView.isHidden = false
            backgroundColor = uiConfig.inboxAvatarBackgroundColor
        }
    }
    
    private func handleNonAvatarModels(_ agent: Agent?, uiConfig: SinchSDKConfig.UIConfig) {
        if let name = agent?.name {
            
            if let firstLetter = name.first?.uppercased() {
                nameLabel.text = firstLetter
            }
            nameLabel.isHidden = false
            imageView.isHidden = true
            backgroundColor = uiConfig.incomingMessageSenderBackgroundColor
            
        } else {
            nameLabel.text = ""
            nameLabel.isHidden = true
            imageView.isHidden = false
            backgroundColor = uiConfig.incomingMessageChatbotBackgroundColor
        }
    }
}
