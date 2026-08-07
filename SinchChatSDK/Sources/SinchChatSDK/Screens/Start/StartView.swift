import UIKit


final class StartView: SinchView {
    
    var messageComposeView: ComposeView
    var collectionView: MessageCollectionView
    let errorView = ErrorView()
    private var state: ChatErrorState = .none
    private var stateToSet: ChatErrorState = .none
    private var workItem: DispatchWorkItem?

    var isErrorViewAnimating = false {
        didSet {
            debugPrint(isErrorViewAnimating)
            if !isErrorViewAnimating && stateToSet != state {
                setErrorViewState(stateToSet)
            }
        }
    }
    let label = UILabel()
    var errorViewTopConstraint: NSLayoutConstraint?
    
    override init(uiConfiguration: SinchSDKConfig.UIConfig, localizationConfiguration: SinchSDKConfig.LocalizationConfig) {
        
        messageComposeView = ComposeView(uiConfiguration: uiConfiguration, localizatioConfiguration: localizationConfiguration)
        collectionView = MessageCollectionView(uiConfiguration: uiConfiguration, localizationConfig:localizationConfiguration)
        super.init(uiConfiguration: uiConfiguration, localizationConfiguration: localizationConfiguration)
        
    }
    
    override func setupSubviews() {
        backgroundColor = uiConfig.backgroundColor
        collectionView.register(TextMessageCell.self, forCellWithReuseIdentifier: TextMessageCell.cellId)
        collectionView.register(ImageMessageCell.self, forCellWithReuseIdentifier: ImageMessageCell.cellId)
        collectionView.register(FileMessageCell.self, forCellWithReuseIdentifier: FileMessageCell.cellId)
        collectionView.register(EventMessageCell.self, forCellWithReuseIdentifier: EventMessageCell.cellId)
        collectionView.register(DateMessageCell.self, forCellWithReuseIdentifier: DateMessageCell.dateCellId)
        collectionView.register(MediaTextMessageCell.self, forCellWithReuseIdentifier: MediaTextMessageCell.cellId)
        collectionView.register(LocationMessageCell.self, forCellWithReuseIdentifier: LocationMessageCell.cellId)
        collectionView.register(ChoicesMessageCell.self, forCellWithReuseIdentifier: ChoicesMessageCell.cellId)
        collectionView.register(CardMessageCell.self, forCellWithReuseIdentifier: CardMessageCell.cellId)
        collectionView.register(CarouselMessageCell.self, forCellWithReuseIdentifier: CarouselMessageCell.cellId)
        collectionView.register(VoiceMessageCell.self, forCellWithReuseIdentifier: VoiceMessageCell.cellId)
        collectionView.register(UnsupportedMessageCell.self, forCellWithReuseIdentifier: UnsupportedMessageCell.cellId)
        collectionView.register(VideoMessageCell.self, forCellWithReuseIdentifier: VideoMessageCell.cellId)
        collectionView.register(TypingIndicatorCell.self, forCellWithReuseIdentifier: TypingIndicatorCell.cellId)

        addSubview(collectionView)
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(errorView)
        errorView.isHidden = true
        errorView.translatesAutoresizingMaskIntoConstraints = false

    }
    override func setupConstraints() {
        
        errorViewTopConstraint = errorView.topAnchor.constraint(equalTo:  self.safeAreaLayoutGuide.topAnchor, constant: -40)
        let errorViewBottom = errorView.bottomAnchor.constraint(equalTo:  collectionView.topAnchor)
        let errorViewLeading = errorView.leadingAnchor.constraint(equalTo:  safeAreaLayoutGuide.leadingAnchor)
        let errorViewTrailing = errorView.trailingAnchor.constraint(equalTo:  safeAreaLayoutGuide.trailingAnchor)
        let errorViewHeight = errorView.heightAnchor.constraint(equalToConstant: 40)
        
        let top = collectionView.topAnchor.constraint(equalTo: errorView.bottomAnchor)
        let bottom = collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        let leading = collectionView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor)
        let trailing = collectionView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor)
        NSLayoutConstraint.activate([top,
                                     bottom,
                                     trailing,
                                     leading,
                                     errorViewBottom,
                                     errorViewLeading,
                                     errorViewTrailing,
                                     errorViewHeight])
        
        guard let errorViewTop = errorViewTopConstraint else {
            return
        }
        
        NSLayoutConstraint.activate([errorViewTop])
        
    }
    
    fileprivate func setWorkingState(_ state: ChatErrorState) {
        self.state = state
        errorView.updateToState(state)
        workItem = DispatchWorkItem {
      
            self.errorViewTopConstraint?.constant = -40
            UIView.animate(withDuration: 0.6, animations: {
                self.isErrorViewAnimating = true
                
                self.layoutIfNeeded()
                
            }, completion: { _ in
                self.errorView.isHidden = true
                self.isErrorViewAnimating = false
                
            })
        }
        if let workItem = workItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1), execute: workItem)
        }

    }
    
    fileprivate func setNonWorkingState(_ state: ChatErrorState) {
        self.state = state
        workItem?.cancel()
        errorView.isHidden = false
        errorView.updateToState(state)
        errorViewTopConstraint?.constant = 0
        UIView.animate(withDuration: 0.6, animations: {
            self.isErrorViewAnimating = true
            
            self.layoutIfNeeded()
            
        }, completion: { _ in
            self.isErrorViewAnimating = false
            
        })
    }
    
    func setErrorViewState(_ state: ChatErrorState) {
        stateToSet = state

        if isErrorViewAnimating {
            
            return
        }
        
        switch state {
        case .isInternetOn:
            
            setWorkingState(state)
            
        case .isInternetOff:
            
            setNonWorkingState(state)

        case .none:
            break
            
        case .agentNotInChat:

            if self.state != .isInternetOff {
                setNonWorkingState(state)
            } else {
                stateToSet = .isInternetOff
            }
            
        case .agentInChat:
            setWorkingState(state)
        }
    }
}
