import UIKit
@MainActor
protocol PlayAudioDelegate: AnyObject {
    func playPauseButtonAction()
}

final class PlayAudioView: SinchView {
    
    var url: URL
    
    lazy var backgroundView: UIView = {
        let backgroundView = UIView()
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.backgroundColor = uiConfig.backgroundColor
        backgroundView.isUserInteractionEnabled = true
        backgroundView.layer.cornerRadius = 10
        backgroundView.clipsToBounds = true
        return backgroundView
    }()
    lazy var progressView: UIProgressView = {
        
        let progressView = UIProgressView()
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = uiConfig.progressBarBackgroundColor
        progressView.isUserInteractionEnabled = true
        progressView.semanticContentAttribute = .forceLeftToRight

        return progressView
    }()
    lazy var timeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.preferredFont(forTextStyle: .caption2)
        label.text = ""
        return label
    }()
    
    lazy var playPauseButton: UIButton = {
        
        let button = UIButton(type: .custom)
        button.setImage(uiConfig.playButtonImage, for:  .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(playPauseButtonAction(_ :)), for: .touchUpInside)
        return button
    }()
    
    lazy var activityIndicator: UIActivityIndicatorView = {

    let activityIndicator: UIActivityIndicatorView = UIActivityIndicatorView(style: .gray)
    activityIndicator.alpha = 1.0
    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    activityIndicator.color = .lightGray
    return activityIndicator
    }()
    
    weak var delegate: PlayAudioDelegate?
    
    init(uiConfiguration: SinchSDKConfig.UIConfig,
         localizationConfiguration: SinchSDKConfig.LocalizationConfig,
         url: URL) {
        
        self.url = url
        super.init(uiConfiguration: uiConfiguration, localizationConfiguration: localizationConfiguration)
        
    }
    
    override func setupSubviews() {
        
        timeLabel.textColor = uiConfig.inAppMessageTextColor
        backgroundView.addSubview(timeLabel)
        backgroundView.addSubview(progressView)
        backgroundView.addSubview(playPauseButton)
        backgroundView.addSubview(activityIndicator)
        addSubview(backgroundView)
        activityIndicator.isHidden = true
    }
    
    override func setupConstraints() {
        
        let backgroundTop = backgroundView.topAnchor.constraint(equalTo: topAnchor)
        let backgroundTrailing = backgroundView.rightAnchor.constraint(equalTo: rightAnchor)
        let backgroundLeading = backgroundView.leftAnchor.constraint(equalTo: leftAnchor)
        let backgroundBottom = backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor)
        
        let playButtonCenter = playPauseButton.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor)
        let playButtonLeading = playPauseButton.leftAnchor.constraint(equalTo: backgroundView.leftAnchor, constant: 20.5)
        let playButtonHeight = playPauseButton.heightAnchor.constraint(equalToConstant: 24.0)
        let playButtonWeidth = playPauseButton.widthAnchor.constraint(equalToConstant: 23.0)
        
        let activityIndicatorCenterY = activityIndicator.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor)
        let activityIndicatorCenterX = activityIndicator.centerXAnchor.constraint(equalTo: playPauseButton.centerXAnchor)

        let activityIndicatorHeight = activityIndicator.heightAnchor.constraint(equalToConstant: 24.0)
        let activityIndicatorWeidth = activityIndicator.widthAnchor.constraint(equalToConstant: 24.0)
        
        let progressViewCenter = progressView.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor, constant: 0)
        let progressViewLeading = progressView.leftAnchor.constraint(equalTo: playPauseButton.rightAnchor, constant: 3.5)
        let progressViewHeight = progressView.heightAnchor.constraint(equalToConstant: 4)
        
        let timeLabelTrailing = timeLabel.rightAnchor.constraint(equalTo: backgroundView.rightAnchor, constant: -24.5)
        let timeLabelLeading = timeLabel.leftAnchor.constraint(equalTo: progressView.rightAnchor, constant: 8)
        let timeLabelCenter = timeLabel.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor)
        let timeLabelWidth = timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 32)

        NSLayoutConstraint.activate([
            backgroundTop,
            backgroundTrailing,
            backgroundBottom,
            backgroundLeading,
            
            playButtonCenter,
            playButtonLeading,
            playButtonHeight,
            playButtonWeidth,
            
            progressViewCenter,
            progressViewLeading,
            progressViewHeight,
            
            timeLabelTrailing,
            timeLabelLeading,
            timeLabelCenter,
            timeLabelWidth,
            
            activityIndicatorCenterX,
            activityIndicatorCenterY,
            activityIndicatorHeight,
            activityIndicatorWeidth
            
        ])
    }
    
    @objc private func playPauseButtonAction(_ sender: UIButton) {
        delegate?.playPauseButtonAction()
        
    }
    func updateViewWithPlayer(_ player: AVPlayerWrapper) {
        var currentProgress = Float(player.currentTime/player.duration)
        let duration =  player.duration.getTimeFromSeconds()
        
        switch player.state {
        case .playing, .buffering:
            playPauseButton.setImage(uiConfig.pauseButtonImage, for:  .normal)
            timeLabel.text = duration
            progressView.setProgress(currentProgress, animated: false)
            activityIndicator.isHidden = true
            playPauseButton.isHidden = false

        case .idle, .ready:
            playPauseButton.setImage(uiConfig.playButtonImage, for:  .normal)
            currentProgress = 0.0
            timeLabel.text = player.duration == 0.0 ? "" : duration
            progressView.setProgress(currentProgress, animated: false)
            activityIndicator.isHidden = true
            playPauseButton.isHidden = false

        case .paused:
            playPauseButton.setImage(uiConfig.playButtonImage, for:  .normal)
            if currentProgress == 1.0 {
                currentProgress = 0.0
                timeLabel.text =  ""

            } else {
                timeLabel.text = duration

            }
            progressView.setProgress(currentProgress, animated: false)
            activityIndicator.isHidden = true
            playPauseButton.isHidden = false

        case .loading:
            playPauseButton.isHidden = true
            activityIndicator.isHidden = false
            activityIndicator.startAnimating()
        }
        
        layoutIfNeeded()
    }
    
    func clearView() {
        
        playPauseButton.setImage(uiConfig.playButtonImage, for:  .normal)
        timeLabel.text = ""
        progressView.setProgress(0.0, animated: true)
        layoutIfNeeded()
    }
}
