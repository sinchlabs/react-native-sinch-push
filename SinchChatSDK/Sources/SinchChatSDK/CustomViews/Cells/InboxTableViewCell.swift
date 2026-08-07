import UIKit

class InboxTableViewCell: UITableViewCell {
    
    var avatarView = AvatarView()
    
    lazy var dotView: UIView = {
        let dotView = UIView()
        dotView.clipsToBounds = true
        dotView.layer.masksToBounds = true
        dotView.layer.cornerRadius = 6
        dotView.backgroundColor = .blue
        dotView.translatesAutoresizingMaskIntoConstraints = false
        
        return dotView
    }()
    lazy var emptyView: UIView = {
        let emptyView = UIView()
        emptyView.backgroundColor = .clear
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        
        return emptyView
    }()
    lazy var topView: UIView = {
        let emptyView = UIView()
        emptyView.backgroundColor = .clear
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        
        return emptyView
    }()
    lazy var avatarEmptyView: UIView = {
        let emptyView = UIView()
        emptyView.backgroundColor = .clear
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        
        return emptyView
    }()
    
    lazy var timeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.preferredFont(forTextStyle: .body)
        
        return label
    }()
    lazy var nameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        if let artistDescriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body).withSymbolicTraits(.traitBold) {
            
            label.font = UIFont(descriptor: artistDescriptor,
                                size: 0.0)
        }
        
        label.numberOfLines = 1
        return label
    }()
    lazy var statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 1
        
        if let artistDescriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body).withSymbolicTraits(.traitBold) {
            
            label.font = UIFont(descriptor: artistDescriptor,
                                size: 0.0)
        }
        return label
    }()
    lazy var lastMessageLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.preferredFont(forTextStyle: .callout)
        label.numberOfLines = 2
        return label
    }()
    lazy var rightStackView: UIStackView = {
        let stackView = UIStackView()
        stackView.distribution = .fill
        stackView.alignment = .leading
        stackView.axis = .vertical
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        return stackView
    }()
    lazy var dateStackView: UIStackView = {
        let stackView = UIStackView()
        stackView.distribution = .fill
        stackView.alignment = .center
        stackView.axis = .horizontal
        stackView.spacing = 14
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        return stackView
    }()
    
    lazy var mainStackView: UIStackView = {
        let stackView = UIStackView()
        stackView.distribution = .fillProportionally
        stackView.alignment = .center
        stackView.axis = .horizontal
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        return stackView
    }()
    var chevronImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = .clear
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        
        return imageView
    }()
    
    var channel: Sinch_Chat_Sdk_V1alpha2_Channel?
    private var dotYCentarPosition: NSLayoutConstraint!
    private var dotYNameCenterPosition: NSLayoutConstraint!
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        emptyView.addSubview(dotView)
        avatarEmptyView.addSubview(avatarView)
        
        mainStackView.addArrangedSubview(emptyView)
        mainStackView.addArrangedSubview(avatarEmptyView)
        mainStackView.addArrangedSubview(rightStackView)
        
        dateStackView.addArrangedSubview(timeLabel)
        dateStackView.addArrangedSubview(chevronImageView)
        
        topView.addSubview(nameLabel)
        topView.addSubview(dateStackView)
        
        rightStackView.addArrangedSubview(topView)
        rightStackView.addArrangedSubview(statusLabel)
        rightStackView.addArrangedSubview(lastMessageLabel)
        
        addSubview(mainStackView)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dateStackView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        
        dotYCentarPosition = dotView.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor)
        dotYNameCenterPosition = dotView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor)
        
        NSLayoutConstraint.activate([
            
            mainStackView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            mainStackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            mainStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            mainStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            
            emptyView.widthAnchor.constraint(equalToConstant: 12.0),
            emptyView.heightAnchor.constraint(equalTo: mainStackView.heightAnchor),
            
            avatarView.widthAnchor.constraint(equalToConstant: 45.0),
            avatarView.heightAnchor.constraint(equalToConstant: 45.0),
            avatarView.centerXAnchor.constraint(equalTo: avatarEmptyView.centerXAnchor),
            avatarView.centerYAnchor.constraint(equalTo: avatarEmptyView.centerYAnchor),
            
            avatarEmptyView.widthAnchor.constraint(equalToConstant: 45.0),
            
            dotView.widthAnchor.constraint(equalToConstant: 12.0),
            dotView.heightAnchor.constraint(equalToConstant: 12.0),
            dotView.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            dotYCentarPosition,
            
            chevronImageView.widthAnchor.constraint(equalToConstant: 6.42),
            chevronImageView.heightAnchor.constraint(equalToConstant: 11.0),
            
            nameLabel.topAnchor.constraint(equalTo: topView.topAnchor, constant: 0),
            nameLabel.bottomAnchor.constraint(equalTo: topView.bottomAnchor, constant: 0),
            nameLabel.leadingAnchor.constraint(equalTo: topView.leadingAnchor, constant: 0),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateStackView.leadingAnchor, constant: -8),
            
            dateStackView.topAnchor.constraint(equalTo: topView.topAnchor, constant: 0),
            dateStackView.bottomAnchor.constraint(equalTo: topView.bottomAnchor, constant: 0),
            dateStackView.trailingAnchor.constraint(equalTo: topView.trailingAnchor, constant: 0),
            
            topView.widthAnchor.constraint(equalTo: rightStackView.widthAnchor)
            
        ])
        
    }
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updateWithChannel(_ channel:Sinch_Chat_Sdk_V1alpha2_Channel, uiConfig: SinchSDKConfig.UIConfig,
                           localizationConfig: SinchSDKConfig.LocalizationConfig) {
        self.channel = channel
        
        lastMessageLabel.textColor = uiConfig.inboxLastMessageTextColor
        nameLabel.textColor = uiConfig.inboxChatNameColor
        statusLabel.textColor = uiConfig.inboxStatusTextColor
        
       //   avatarView.updateWithChannel(channel, uiConfig: uiConfig)
        
        avatarEmptyView.isHidden = true
        dotYCentarPosition.isActive = false
        dotYNameCenterPosition.isActive = true
        
        timeLabel.textColor = uiConfig.inboxDateTextColor
        chevronImageView.image = uiConfig.inboxChevronRightImage
        dotView.backgroundColor = uiConfig.inboxNotificationDotColor
        
        statusLabel.text = channel.status == .open ? "\(localizationConfig.inboxStatusText) \(localizationConfig.inboxStatusOpenText)" : "\(localizationConfig.inboxStatusText) \(localizationConfig.inboxStatusClosedText)"
        
        nameLabel.text = channel.displayName.isEmpty ? channel.channelID.components(separatedBy: "/").last ?? "" : channel.displayName
  
       // statusLabel.text = "Status - Open"
        
        if channel.hasLastEntry {
            guard let message = handleIncomingMessage(channel.lastEntry) else {
                lastMessageLabel.text = "\n"
                timeLabel.text = ""
                return
            }
            debugPrint(channel.hasSeenAt)
            debugPrint(channel.seenAt.seconds)

            if channel.lastEntry.hasDeliveryTime && channel.hasSeenAt {
                
                dotView.isHidden =  channel.seenAt.seconds > channel.lastEntry.deliveryTime.seconds
            } else {
                dotView.isHidden = true
            }

            dotView.layoutIfNeeded()

            lastMessageLabel.text = (message.convertToText ?? "") + "\n"
            
            if channel.hasUpdatedAt {
                let date = Date(timeIntervalSince1970: TimeInterval(channel.updatedAt.seconds))
                timeLabel.text = date.getInboxFormattedDate(localizationConfiguration: localizationConfig)
            } else {
                timeLabel.text = ""
            }
        }
    }
}
