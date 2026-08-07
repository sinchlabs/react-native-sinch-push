import UIKit
// import SnapshotTesting

@MainActor
protocol ComposeViewDelegate: AnyObject {
    
    func sendMessage(_ messageType: MessageType)
    func sendVoiceMessage(url: URL)
    func sendChoiceResponseMessage(postbackData: String, entryID: String)
    func choosePhoto()
    func chooseAction()
    func startPlayingRecordedMessage(url: URL)
    func stopAudioPlayerIfPlaying(isRecording:Bool)
    func disabledMicrophoneAccess()
    func showHoldToRecordAudioMessage()
    func scrollToBottomMessage()
    func composeMessageStarted()
    func composeMessageEnded()

}

// swiftlink:disable:next type_body_length
final class ComposeView: SinchView {
    
    var isSendingMessagesEnabled: Bool = true {
        didSet {
            if isSendingMessagesEnabled {
                enableSendingMessages()
            } else {
                disableSendingMessages()
            }
        }
    }
    
    private let maxHeight: CGFloat = 125.0
    private let minHeight: CGFloat = 60.0
    private let paddingTop: CGFloat = 10.0
    private let paddingBottom: CGFloat = 10.0
    private let animationDuration: Double = 0.2
    private let recordingAnimationDuration: Double = 0.1
    private let spacingBetweenButtonsAndText: Double = 9.0
    private var composeStartEventSentTime: Date?
    
    lazy var voiceRecordingButton: UIButton = {
        var button = UIButton()
        button.setImage(uiConfig.voiceRecordingImage, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        
        return button
    }()
    
    lazy var emptyView: UIView = {
        var view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    lazy var rightStackEmptyView: UIView = {
        var view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    lazy var photoButton: UIButton = {
        var button = UIButton()
        button.setImage(uiConfig.photoImage, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        
        return button
    }()
    
    lazy var sendButton: UIButton = {
        var button = UIButton()
        button.setImage(uiConfig.sendImage, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        
        return button
    }()
    
    lazy var plusButton: UIButton = {
        var button = UIButton()
        button.setImage(uiConfig.plusImage, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        
        return button
    }()
    
    lazy var disabledTextLabel: UILabel = {
        let label = UILabel()
        label.text = localizationConfiguration.disabledChatMessageText
        label.translatesAutoresizingMaskIntoConstraints = false
        
        return label
    }()
    
    var placeholderLabel: UILabel = UILabel()
    var textButtonContainer: UIView = UIView()
    var leftStackView: UIStackView = UIStackView()
    var rightStackView: UIStackView = UIStackView()
    
    lazy var recordingLabel: UILabel =  {
        var label = UILabel()
        label.text = localizationConfiguration.recordingTitle
        label.textColor = uiConfig.recordingRedColor
        label.textAlignment = .right
        label.font = UIFont.systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    lazy var timeLabel: UILabel =  {
        var label = UILabel()
        label.text = duration.getTimeFromSeconds()
        label.textAlignment = .left
        label.font = UIFont.systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        
        return label
        
    }()
    var url: URL?
    
    lazy var voiceRecorder: VoiceRecorderController! = {
        let recorder = VoiceRecorderController()
        recorder.delegate = self
        return recorder
    }()
    lazy var scrollToBottomButton: UIButton = {
        let scrollToBottomButton = UIButton(type: .custom)
        scrollToBottomButton.backgroundColor = uiConfig.inputBarBackgroundColor
        scrollToBottomButton.layer.borderColor = uiConfig.inputTextViewBorderColor.cgColor
        scrollToBottomButton.layer.borderWidth = 1.0
        scrollToBottomButton.layer.cornerRadius = 12.0
        scrollToBottomButton.imageView?.contentMode = .scaleAspectFit
        scrollToBottomButton.setImage(uiConfig.scrollToBottomImage, for: .normal)
        scrollToBottomButton.translatesAutoresizingMaskIntoConstraints = false
        return scrollToBottomButton
    }()

    var audioBackgroundView: AudioComposeView?
    var backgroundView: UIView = UIView()
    var shouldExpandTextViewToRight = true
    weak var delegate: ComposeViewDelegate?
    var composeTextView: ComposeTextView!
    
    private var isInputTextViewExpanded: Bool = false
    private var leftStackViewConstraint: NSLayoutConstraint!
    private var rightStackViewConstraint: NSLayoutConstraint!
    private var rightStackViewLeadingConstraint: NSLayoutConstraint!
    
    private var sendButtonBottomConstraint: NSLayoutConstraint!
    private var textContainerBottomAnchor: NSLayoutConstraint!
    private var windowAnchor: NSLayoutConstraint?
    
    private var backgroundViewBottomAnchor: NSLayoutConstraint!
    private var textViewMaxHeight: NSLayoutConstraint!
    var duration: Double = 0.0 {
        didSet {
            timeLabel.text = duration.getTimeFromSeconds()
        }
    }
    private var timer: Timer?
    
    init(uiConfiguration: SinchSDKConfig.UIConfig, localizatioConfiguration: SinchSDKConfig.LocalizationConfig) {
        
        composeTextView = ComposeTextView(configuration: uiConfiguration)
        super.init(uiConfiguration: uiConfiguration, localizationConfiguration: localizatioConfiguration)
    }
    
    override func setupSubviews() {

        translatesAutoresizingMaskIntoConstraints = false
        backgroundView.backgroundColor = uiConfig.inputBarBackgroundColor
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)
        addLeftContentButtons()
        addRightContentButtons()
        addTextViewAndSendButtonContainer()
        setupPlaceholderLabel()
        setupScrollToBottomButton()
        setupButtonVisibility()
    }
    
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        
        if scrollToBottomButton.point(inside: convert(point, to: scrollToBottomButton), with: event) {
            return true
        }
        
        return super.point(inside: point, with: event)
    }
    override func setupConstraints() {
        var leftWidth = 0.0
        if !(SinchChatSDK.shared.disabledFeatures.contains(.sendLocationSharingMessage) &&
            SinchChatSDK.shared.disabledFeatures.contains(.sendDocuments)) {
            leftWidth = 38.0
        }
        
        leftStackViewConstraint = leftStackView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 18)
        rightStackViewConstraint = rightStackView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -18)
        sendButtonBottomConstraint = sendButton.bottomAnchor.constraint(equalTo: textButtonContainer.bottomAnchor)
        backgroundViewBottomAnchor =  backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor)
        textContainerBottomAnchor =  textButtonContainer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10)
        textViewMaxHeight = composeTextView.heightAnchor.constraint(equalToConstant: maxHeight - paddingTop - paddingBottom)
        
        recordingLabel.setContentHuggingPriority(.required, for: .horizontal)
        emptyView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        voiceRecordingButton.setContentHuggingPriority(.required, for: .horizontal)
        
        NSLayoutConstraint.activate([
            
            leftStackViewConstraint,
            leftStackView.trailingAnchor.constraint(equalTo: textButtonContainer.leadingAnchor, constant: -spacingBetweenButtonsAndText),
            leftStackView.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor, constant: 0),
            leftStackView.widthAnchor.constraint(equalToConstant:leftWidth),
            rightStackViewConstraint,
            rightStackView.leadingAnchor.constraint(equalTo: textButtonContainer.trailingAnchor, constant: 9),
            rightStackView.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor, constant: 0),
            
            scrollToBottomButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: -10),
            scrollToBottomButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: 10),
            scrollToBottomButton.widthAnchor.constraint(equalToConstant: 48),
            scrollToBottomButton.heightAnchor.constraint(equalToConstant: 48),
            
            // timeLabel.widthAnchor.constraint(equalToConstant: 70),
            timeLabel.heightAnchor.constraint(equalToConstant: 40),
            emptyView.heightAnchor.constraint(equalToConstant: 40),
            recordingLabel.heightAnchor.constraint(equalToConstant: 40),
            
            plusButton.heightAnchor.constraint(equalToConstant: 40),
            plusButton.widthAnchor.constraint(equalToConstant: 38),
            
            rightStackEmptyView.heightAnchor.constraint(equalToConstant: 40),
            rightStackEmptyView.widthAnchor.constraint(equalToConstant: 0),
            
            photoButton.heightAnchor.constraint(equalToConstant: 40),
            photoButton.widthAnchor.constraint(equalToConstant: 38),
            
            voiceRecordingButton.heightAnchor.constraint(equalToConstant: 40),
            voiceRecordingButton.widthAnchor.constraint(equalToConstant: 38),
            
            backgroundView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            backgroundViewBottomAnchor,
            backgroundView.leftAnchor.constraint(equalTo: safeAreaLayoutGuide.leftAnchor),
            backgroundView.rightAnchor.constraint(equalTo: safeAreaLayoutGuide.rightAnchor),
            
            textButtonContainer.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 10),
            textContainerBottomAnchor,
            
            composeTextView.leftAnchor.constraint(equalTo: textButtonContainer.leftAnchor, constant: 10),
            composeTextView.rightAnchor.constraint(equalTo: textButtonContainer.rightAnchor, constant: -45),
            composeTextView.topAnchor.constraint(equalTo: textButtonContainer.topAnchor, constant: 0),
            composeTextView.bottomAnchor.constraint(equalTo: textButtonContainer.bottomAnchor, constant: 0),
            
            sendButton.rightAnchor.constraint(equalTo: textButtonContainer.rightAnchor, constant: -10),
            sendButton.heightAnchor.constraint(equalToConstant: 30),
            sendButton.widthAnchor.constraint(equalToConstant: 30),
            sendButtonBottomConstraint,
            
            placeholderLabel.leftAnchor.constraint(equalTo: composeTextView.leftAnchor, constant: 8),
            placeholderLabel.rightAnchor.constraint(equalTo: composeTextView.rightAnchor, constant: 0),
            placeholderLabel.topAnchor.constraint(equalTo: composeTextView.topAnchor, constant: 0),
            placeholderLabel.bottomAnchor.constraint(equalTo: composeTextView.bottomAnchor, constant: 0)
        ])
    }
    
    func setupButtonVisibility() {
        let isPlusButtonAvailable = (SinchChatSDK.shared.disabledFeatures.contains(.sendLocationSharingMessage) && SinchChatSDK.shared.disabledFeatures.contains(.sendDocuments))
        plusButton.isHidden = isPlusButtonAvailable
        
        let isPhotoAvailable = (SinchChatSDK.shared.disabledFeatures.contains(.sendImageMessageFromGallery) &&
                                SinchChatSDK.shared.disabledFeatures.contains(.sendVideoMessageFromGallery) &&
                                SinchChatSDK.shared.disabledFeatures.contains(.sendImageFromCamera))

        photoButton.isHidden = isPhotoAvailable
        voiceRecordingButton.isHidden = SinchChatSDK.shared.disabledFeatures.contains(.sendVoiceMessage)
        
    }
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window = window, window.safeAreaInsets.bottom > 0 else { return }
        windowAnchor?.isActive = false
        windowAnchor = textButtonContainer.bottomAnchor.constraint(lessThanOrEqualToSystemSpacingBelow: window.safeAreaLayoutGuide.bottomAnchor, multiplier: 1)
        windowAnchor?.constant = 0
        windowAnchor?.priority = UILayoutPriority(rawValue: 750)
        windowAnchor?.isActive = true
        backgroundViewBottomAnchor.constant = window.safeAreaInsets.bottom
    }
    
    override func resignFirstResponder() -> Bool {
        composeTextView.resignFirstResponder()
        return super.resignFirstResponder()
    }
    
    func setText(_ text: String) {
        composeTextView.text = text
        showHidePlaceholderAndSendButton(in: composeTextView)
    }
    
    // MARK: - Private
    
    private func setupScrollToBottomButton() {
        scrollToBottomButton.isHidden = true
        scrollToBottomButton.addTarget(self, action: #selector(scrollToBottom), for: .touchUpInside)
        addSubview(scrollToBottomButton)
        bringSubviewToFront(scrollToBottomButton)
    }
    private func setupPlaceholderLabel() {
        
        placeholderLabel.font = UIFont.preferredFont(forTextStyle: .body)
        placeholderLabel.textColor = uiConfig.inputPlaceholderTextColor
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.numberOfLines = 1
        placeholderLabel.backgroundColor = .clear
        placeholderLabel.text = localizationConfiguration.inputPlaceholderText
        textButtonContainer.addSubview(placeholderLabel)
    }
    
    private func setupTextView() {
        composeTextView.delegate = self
        composeTextView.translatesAutoresizingMaskIntoConstraints = false
    }
    
    private func addTextViewAndSendButtonContainer() {
        
        textButtonContainer.backgroundColor =  uiConfig.inputTextViewBackgroundColor
        textButtonContainer.layer.cornerRadius = 20.0
        textButtonContainer.layer.borderWidth = 1.0
        textButtonContainer.layer.borderColor = uiConfig.inputTextViewBorderColor.cgColor
        textButtonContainer.clipsToBounds = true
        textButtonContainer.translatesAutoresizingMaskIntoConstraints = false
        
        setupTextView()
        textButtonContainer.addSubview(composeTextView)
        
        setupSendButton()
        textButtonContainer.addSubview(sendButton)
        
        backgroundView.addSubview(textButtonContainer)
    }
    
    private func setupSendButton() {
        sendButton.imageEdgeInsets = UIEdgeInsets(top: 7.01, left: 5, bottom: 6.67, right: 5)
        sendButton.addTarget(self, action: #selector(sendMessage(_:)), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.isHidden = true
    }
    
    private func addLeftContentButtons() {
        
        plusButton.imageEdgeInsets = UIEdgeInsets(top: 8, left: 7, bottom: 8, right: 7)
        plusButton.addTarget(self, action: #selector(plusButtonAction(_:)), for: .touchUpInside)
        leftStackView.addArrangedSubview(plusButton)
        leftStackView.distribution = .fill
        leftStackView.alignment = .center
        leftStackView.axis = .horizontal
        leftStackView.spacing = 2
        leftStackView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.addSubview(leftStackView)
    }
    
    private func addRightContentButtons() {
        
        photoButton.imageEdgeInsets = UIEdgeInsets(top: 8, left: 7, bottom: 8, right: 7)
        voiceRecordingButton.imageEdgeInsets = UIEdgeInsets(top: 8, left: 7, bottom: 8, right: 7)
        let longGesture = UILongPressGestureRecognizer(target: self,
                                                       action: #selector(handleLongPress(gestureReconizer: )))
        
        voiceRecordingButton.addGestureRecognizer(longGesture)
        let tapGesture = UITapGestureRecognizer(target: self,
                                                action: #selector(tapVoiceRecorder(gestureReconizer: )))
        
        voiceRecordingButton.addGestureRecognizer(tapGesture)
        photoButton.addTarget(self, action: #selector(photoAction(_:)), for: .touchUpInside)
        timeLabel.isHidden = true
        recordingLabel.isHidden = true
        emptyView.isHidden = true
        rightStackEmptyView.isHidden = false
        rightStackView.addArrangedSubview(timeLabel)
        rightStackView.addArrangedSubview(emptyView)
        rightStackView.addArrangedSubview(recordingLabel)
        rightStackView.addArrangedSubview(photoButton)
        rightStackView.addArrangedSubview(rightStackEmptyView)
        rightStackView.addArrangedSubview(voiceRecordingButton)
        
        rightStackView.distribution = .fill
        rightStackView.alignment = .center
        rightStackView.axis = .horizontal
        rightStackView.spacing = 2
        rightStackView.translatesAutoresizingMaskIntoConstraints = false
        
        backgroundView.addSubview(rightStackView)
    }
    private func updateTextContainerCornerRadius(_ totalHeight: CGFloat) {
        
        if totalHeight < 60 {
            textButtonContainer.layer.cornerRadius = (totalHeight-20 )/2
        } else {
            textButtonContainer.layer.cornerRadius = 20.0
        }
    }
    
    private func updateButton(_ totalHeight: CGFloat) {
        
        guard let fontHeight = composeTextView.font?.lineHeight else { return }
        let numLines = Int((totalHeight - composeTextView.textContainerInset.top - composeTextView.textContainerInset.bottom) / fontHeight)
        let imageHeight: CGFloat = 16.32
        let topImageInset: CGFloat = 7.01
        let bottomImageInset: CGFloat = 6.67
        
        if numLines == 1 {
            let totalInset = totalHeight - imageHeight - topImageInset - bottomImageInset
            sendButtonBottomConstraint.constant = -abs(totalInset)/2
        }
    }
    
    override var intrinsicContentSize: CGSize {
        let size = composeTextView.sizeThatFits(CGSize(width: composeTextView.frame.width, height: CGFloat(MAXFLOAT)))
        let totalHeight = (audioBackgroundView != nil) ? 120 : size.height + paddingTop + paddingBottom
        if totalHeight <= maxHeight {
            updateTextContainerCornerRadius(totalHeight)
            updateButton(size.height)
            textViewMaxHeight.isActive = false
            composeTextView.isScrollEnabled = false
            
            composeTextView.invalidateIntrinsicContentSize()
            
            return CGSize(width: self.bounds.width, height: totalHeight)
            
        } else {
            composeTextView.isScrollEnabled = true
            textViewMaxHeight.isActive = true
            
            return CGSize(width: self.bounds.width, height: maxHeight)
        }
    }
    
    @objc private func scrollToBottom(_ sender: UIButton) {
        delegate?.scrollToBottomMessage()
        
    }
    @objc private func photoAction(_ sender: UIButton) {
        
        delegate?.choosePhoto()
        
    }
    @objc private func plusButtonAction(_ sender: UIButton) {
        delegate?.chooseAction()
    }
    
    @objc func handleLongPress(gestureReconizer: UILongPressGestureRecognizer) {
        let generator = UIImpactFeedbackGenerator(style: .medium)

        if gestureReconizer.state == .began {
            
            if !composeTextView.text.isEmpty {
                composeTextView.text = nil
                updateUI(composeTextView)
            }
            delegate?.stopAudioPlayerIfPlaying(isRecording: true)
            voiceRecorder.startRecordingSession()
                generator.prepare()
                generator.impactOccurred()
        } else if gestureReconizer.state == .ended {
            voiceRecorder.shouldRecord = false
            voiceRecorder.finishRecording()
                generator.prepare()
                generator.impactOccurred()
        }
    }
    @objc func tapVoiceRecorder(gestureReconizer: UITapGestureRecognizer) {
        
        delegate?.showHoldToRecordAudioMessage()
        
    }
    
    func updateAudioComposeView(player: AVPlayerWrapper) {
        audioBackgroundView?.updateViewWithPlayer(player)
    }
    
    @objc private func sendMessage(_ sender: UIButton) {
        
        guard let text = composeTextView.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return
        }
        self.delegate?.composeMessageEnded()

        composeTextView.text = nil
        delegate?.sendMessage(.text(text))
        updateUI(composeTextView)
    }
    
    func voiceRecordingStartedUpdateView() {
        duration = 0.0
        leftStackViewConstraint?.constant = -(leftStackView.frame.maxX + spacingBetweenButtonsAndText + textButtonContainer.frame.width)
        
        rightStackViewLeadingConstraint = rightStackView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 9)
        rightStackViewLeadingConstraint.isActive = true
        
        UIView.animate(withDuration: recordingAnimationDuration, animations: {
            self.recordingLabel.isHidden = false
            self.timeLabel.isHidden = false
            self.photoButton.isHidden = true
            self.emptyView.isHidden = false
            
            self.layoutIfNeeded()
            
        })
    }
    
    func finishedVoiceRecordingUpdateView(url: URL) {
        
        audioBackgroundView = AudioComposeView(uiConfiguration: uiConfig, localizationConfiguration: localizationConfiguration, url: url, duration: duration)
        guard let audioBackgroundView = audioBackgroundView else { return }
        
        audioBackgroundView.delegate = self
        audioBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.addSubview(audioBackgroundView)
        NSLayoutConstraint.activate([
            audioBackgroundView.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            audioBackgroundView.leftAnchor.constraint(equalTo: backgroundView.leftAnchor),
            audioBackgroundView.rightAnchor.constraint(equalTo: backgroundView.rightAnchor),
            audioBackgroundView.heightAnchor.constraint(equalToConstant: 120.0)
            
        ])
        
        leftStackViewConstraint?.constant = 18
        rightStackViewLeadingConstraint.isActive = false
        
        self.layoutIfNeeded()
        
        self.recordingLabel.isHidden = true
        self.timeLabel.isHidden = true
        setupButtonVisibility() 
        self.emptyView.isHidden = true
        
        invalidateIntrinsicContentSize()
        
    }
    private func expandTextView() {
        if !isInputTextViewExpanded {
            
            let width = rightStackView.frame.width
            isInputTextViewExpanded = true
            
            if width != 0 {
                rightStackViewConstraint?.constant = width
            }
            rightStackViewLeadingConstraint?.constant = 25
            UIView.animate(withDuration: animationDuration, animations: {
                self.layoutIfNeeded()
                
            })
        }
    }
    
    private func collapseTextView() {
        
        if isInputTextViewExpanded {
            isInputTextViewExpanded = false
            rightStackViewConstraint?.constant = -18
            rightStackViewLeadingConstraint?.constant = 9
            
            UIView.animate(withDuration: animationDuration) {
                
                self.layoutIfNeeded()
            }
        }
    }
    private func updateUI(_ textView: UITextView) {
        updateTextViewConstraints()
        
        if shouldExpandTextViewToRight {
            if textView.text.isEmpty {

                collapseTextView()
            } else {

                expandTextView()
            }
        }
        showHidePlaceholderAndSendButton(in: textView)
    }
    
    private func showHidePlaceholderAndSendButton(in textView: UITextView) {
        if !textView.hasText || textView.text.isEmpty {
            
            placeholderLabel.isHidden = false
            sendButton.isHidden = true
        } else {
            
            placeholderLabel.isHidden = true
            sendButton.isHidden = false
        }
    }
    
    private func updateTextViewConstraints() {
        invalidateIntrinsicContentSize()
        updateConstraints()
    }
    
    private func enableSendingMessages() {
        disabledTextLabel.isHidden = true
        
        leftStackView.isHidden = false
        rightStackView.isHidden = false
        textButtonContainer.isHidden = false
    }
    
    private func disableSendingMessages() {
        leftStackView.isHidden = true
        rightStackView.isHidden = true
        textButtonContainer.isHidden = true
        
        disabledTextLabel.isHidden = false
        if disabledTextLabel.superview == nil {
            addSubview(disabledTextLabel)
            
            NSLayoutConstraint.activate([
                disabledTextLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                disabledTextLabel.topAnchor.constraint(equalTo: topAnchor, constant: paddingTop)
            ])
        }
    }
}

extension ComposeView: UITextViewDelegate {
    
    func textViewDidBeginEditing(_ textView: UITextView) {
        
        textView.selectedRange = NSRange(location: textView.text.count, length: 0)

    }
    
    func textViewDidEndEditing(_ textView: UITextView) {
        
        updateUI(textView)

    }
    
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        !voiceRecorder.isRecording
    
    }
    
    func textViewDidChange(_ textView: UITextView) {
        
        updateUI(textView)
        sendComposeMessageEvents()
        
    }
    func scheduleComposeMessageEnd() {
        timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in

            guard let self = self else { return }

            Task { @MainActor in
                self.delegate?.composeMessageEnded()
            }

        }
    }
    
    func sendComposeMessageEvents() {
        
        if let composeStartEventSentTime = composeStartEventSentTime {
            let now =  Date()
            let delta = now - composeStartEventSentTime
            if Double(delta) > 2.0 {
                self.composeStartEventSentTime = now
                delegate?.composeMessageStarted()
                scheduleComposeMessageEnd()
            }
        } else {
            
            composeStartEventSentTime = Date()
            delegate?.composeMessageStarted()
            scheduleComposeMessageEnd()
        }
    }
}
extension ComposeView: AudioComposeDelegate {
    private func handleDeleteAndUpdateView() {
        duration = 0.0
        audioBackgroundView?.removeFromSuperview()
        audioBackgroundView = nil
        invalidateIntrinsicContentSize()
        delegate?.stopAudioPlayerIfPlaying(isRecording: false)
        
    }
    
    func deleteRecording(url: URL) {
        
        voiceRecorder.removeRecording()
        handleDeleteAndUpdateView()
        
    }
    
    func sendRecording(url: URL) {
        
        delegate?.sendVoiceMessage(url: url)
        // TODO delete file if successful
        voiceRecorder.duration = 0.0
        handleDeleteAndUpdateView()
    }
    
    func continueRecording(url: URL) {
        voiceRecorder.continueRecording()
    }
    
    func playRecording(url: URL) {
        delegate?.startPlayingRecordedMessage(url: url)
    }
    
}
// MARK: - Conforming to VoiceRecordingProtocol
extension ComposeView: VoiceRecordingProtocol {
    func doNotHaveMicrophoneAccess() {
        delegate?.disabledMicrophoneAccess()
    }
    
    func updateTime(_ duration: Double) {
        self.duration = duration
        debugPrint(duration)
        if let audioBackgroundView = audioBackgroundView {
            audioBackgroundView.duration = Double(duration)
        }
    }
    
    func recordingStarted(_ duration: Double, url: URL) {
        debugPrint("started")
        voiceRecordingStartedUpdateView()
    }
    
    func recordingContinued(_ duration: Double, url: URL) {
        if let audioBackgroundView = audioBackgroundView {
            audioBackgroundView.duration = Double(duration)
            audioBackgroundView.recordButton.setImage(uiConfig.pauseButtonImage, for: .normal)
            
        }
    }
    
    func recordingFinished(_ duration: Double, url: URL) {
        
        if let audioBackgroundView = audioBackgroundView {
            audioBackgroundView.duration = duration
        }
    }
    
    func errorSavingVoiceMessage(text: String) {
        debugPrint("error")
    }
    
    func successfullySavedVoiceMessage(url: URL) {
        finishedVoiceRecordingUpdateView(url: url)
    }
}
