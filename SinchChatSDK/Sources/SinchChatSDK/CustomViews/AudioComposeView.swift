import UIKit
@MainActor
protocol AudioComposeDelegate: AnyObject {
    
    func deleteRecording(url: URL)
    func sendRecording(url: URL)
    func continueRecording(url: URL)
    func playRecording(url: URL)

}

final class AudioComposeView: SinchView {
    
    lazy var buttonsBackgroundView: UIView = {
        let backgroundView = UIView()
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.backgroundColor = uiConfig.primaryAudioBarBackgroundColor
        
        return backgroundView
    }()
    
    lazy var playAudioView: PlayAudioView = {
        let backgroundView = PlayAudioView(uiConfiguration: uiConfig,
                                           localizationConfiguration: localizationConfiguration,
                                           url: url)
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.delegate = self
        return backgroundView
    }()
    
    lazy var deleteButton: UIButton = {
        
        let button = UIButton(type: .custom)
        button.setImage(uiConfig.deleteImage, for:  .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(deleteButtonAction(_ :)), for: .touchUpInside)
        return button
    }()
    
    lazy var recordButton: UIButton = {
        
        let button = UIButton(type: .custom)
        button.setImage(uiConfig.recordButtonImage, for:  .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(recordButtonAction(_ :)), for: .touchUpInside)
        return button
    }()
    
    lazy var sendButton: UIButton = {
        
        let button = UIButton(type: .custom)
        button.setImage(uiConfig.sendFilledImage, for:  .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(sendButtonAction(_ :)), for: .touchUpInside)
        return button
    }()
    
    var url: URL
    var duration: Double {
       
        didSet {
            playAudioView.timeLabel.text = duration.getTimeFromSeconds()
        }
    }
    
    weak var delegate: AudioComposeDelegate?
    
    init(uiConfiguration: SinchSDKConfig.UIConfig,
         localizationConfiguration: SinchSDKConfig.LocalizationConfig,
         url: URL, duration: Double) {
        
        self.url = url
        self.duration = duration
        
        super.init(uiConfiguration: uiConfiguration, localizationConfiguration: localizationConfiguration)
        
    }
    
    override func setupSubviews() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor =  uiConfig.topAudioBarBackgroundColor
        addSubview(buttonsBackgroundView)
        addSubview(playAudioView)
        
        buttonsBackgroundView.addSubview(deleteButton)
        buttonsBackgroundView.addSubview(recordButton)
        buttonsBackgroundView.addSubview(sendButton)

        playAudioView.timeLabel.text = duration.getTimeFromSeconds()
        recordButton.isHidden = true
    }
    
    override func setupConstraints() {
        
        let playAudioViewTop = playAudioView.topAnchor.constraint(equalTo: topAnchor, constant: 9.0)
        let playAudioViewTrailing = playAudioView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -70.0)
        let playAudioViewLeading = playAudioView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 70.0)
        let playAudioViewHeight = playAudioView.heightAnchor.constraint(equalToConstant: 32.0)

        let buttonsBackgroundViewTop = buttonsBackgroundView.topAnchor.constraint(equalTo: playAudioView.bottomAnchor, constant: 8)
        let buttonsBackgroundViewTrailing = buttonsBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor)
        let buttonsBackgroundViewLeading = buttonsBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let buttonsBackgroundViewBottom = buttonsBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor)
        
        let recordCenterX = recordButton.centerXAnchor.constraint(equalTo: buttonsBackgroundView.centerXAnchor)
        let recordTop = recordButton.topAnchor.constraint(equalTo: buttonsBackgroundView.topAnchor, constant: 18)
        let recordHeight = recordButton.heightAnchor.constraint(equalToConstant: 32.0)
        let recordWidth = recordButton.widthAnchor.constraint(equalToConstant: 32.0)
        
        let deleteLeading = deleteButton.leadingAnchor.constraint(equalTo: buttonsBackgroundView.leadingAnchor, constant: 15)
        let deleteTop = deleteButton.topAnchor.constraint(equalTo: buttonsBackgroundView.topAnchor, constant: 18)
        let deleteHeight = deleteButton.heightAnchor.constraint(equalToConstant: 32.0)
        let deleteWidth = deleteButton.widthAnchor.constraint(equalToConstant: 32.0)
        
        let sendLeading = sendButton.trailingAnchor.constraint(equalTo: buttonsBackgroundView.trailingAnchor, constant: -15)
        let sendTop = sendButton.topAnchor.constraint(equalTo: buttonsBackgroundView.topAnchor, constant: 18)
        let sendHeight = sendButton.heightAnchor.constraint(equalToConstant: 32.0)
        let sendWidth = sendButton.widthAnchor.constraint(equalToConstant: 32.0)
        
        NSLayoutConstraint.activate([
            playAudioViewTop,
            playAudioViewTrailing,
            playAudioViewLeading,
            playAudioViewHeight,
            
            buttonsBackgroundViewTop,
            buttonsBackgroundViewTrailing,
            buttonsBackgroundViewLeading,
            buttonsBackgroundViewBottom,
            
            recordCenterX,
            recordTop,
            recordHeight,
            recordWidth,

            deleteLeading,
            deleteTop,
            deleteHeight,
            deleteWidth,
            
            sendLeading,
            sendTop,
            sendHeight,
            sendWidth
            
        ])
    }
    
    @objc func deleteButtonAction(_ sender: AnyObject) {
        delegate?.deleteRecording(url: url)
    }
    
    @objc func recordButtonAction(_ sender: AnyObject) {
        delegate?.continueRecording(url:url)
    }
    
    @objc func sendButtonAction(_ sender: AnyObject) {
        delegate?.sendRecording(url: url)
    }
    
    func updateViewWithPlayer(_ player: AVPlayerWrapper) {
        playAudioView.updateViewWithPlayer(player)
        if playAudioView.timeLabel.text == "" {
            playAudioView.timeLabel.text = duration.getTimeFromSeconds()
        }
    }
}
extension AudioComposeView : PlayAudioDelegate {
    func playPauseButtonAction() {
        delegate?.playRecording(url: url)
    }
}
