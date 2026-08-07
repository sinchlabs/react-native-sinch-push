import UIKit
import Network

internal extension StartViewController {
    
    func addNoInternetObservers() {
        
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { [weak self] in
                if path.status == .satisfied {
                    self?.viewModel.setInternetConnectionState(.isOn)
                    SinchChatSDK.shared.eventListenerSubject.send(.didChangeInternetState(isOn:true))
                } else {
                    self?.viewModel.setInternetConnectionState(.isOff)
                    SinchChatSDK.shared.eventListenerSubject.send(.didChangeInternetState(isOn:false))

                }
            }
        }
        let queue = DispatchQueue(label: "internetConnectionMonitor")
        monitor.start(queue: queue)
    }

    func addKeyboardObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(StartViewController.handleKeyboardDidChangeState(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(StartViewController.handleTextViewDidBeginEditing(_:)),
                                               name: UITextView.textDidBeginEditingNotification, object: nil)        
    }
    
    func removeKeyboardObservers() {
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UITextView.textDidBeginEditingNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
    }
    
    // MARK: - Notification Handlers
    
     @objc
    private func handleTextViewDidBeginEditing(_ notification: Notification) {
            guard
                let inputTextView = notification.object as? ComposeTextView,
                inputTextView === mainView.messageComposeView.composeTextView
            else {
                return
            }
        if mainView.collectionView.contentOffset.y >=
            (mainView.collectionView.contentSize.height - mainView.collectionView.frame.size.height) {
            mainView.collectionView.scrollToLastItem()
        }        
    }
    @objc
    private func handleKeyboardDidChangeState(_ notification: Notification) {
        guard !isMessagesControllerBeingDismissed else { return }
        
        guard let keyboardStartFrameInScreenCoords = notification.userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect else { return }
        guard !keyboardStartFrameInScreenCoords.isEmpty || UIDevice.current.userInterfaceIdiom != .pad else {
            // WORKAROUND for what seems to be a bug in iPad's keyboard handling in iOS 11: we receive an extra spurious frame change
            // notification when undocking the keyboard, with a zero starting frame and an incorrect end frame. The workaround is to
            // ignore this notification.
            return
        }
        
        guard self.presentedViewController == nil else {
            // This is important to skip notifications from child modal controllers in iOS >= 13.0
            return
        }
        
        // Note that the check above does not exclude all notifications from an undocked keyboard, only the weird ones.
        //
        // We've tried following Apple's recommended approach of tracking UIKeyboardWillShow / UIKeyboardDidHide and ignoring frame
        // change notifications while the keyboard is hidden or undocked (undocked keyboard is considered hidden by those events).
        // Unfortunately, we do care about the difference between hidden and undocked, because we have an input bar which is at the
        // bottom when the keyboard is hidden, and is tied to the keyboard when it's undocked.
        //
        // If we follow what Apple recommends and ignore notifications while the keyboard is hidden/undocked, we get an extra inset
        // at the bottom when the undocked keyboard is visible (the inset that tries to compensate for the missing input bar).
        // (Alternatives like setting newBottomInset to 0 or to the height of the input bar don't work either.)
        //
        // We could make it work by adding extra checks for the state of the keyboard and compensating accordingly, but it seems easier
        // to simply check whether the current keyboard frame, whatever it is (even when undocked), covers the bottom of the collection
        // view.
        
        guard let keyboardEndFrameInScreenCoords = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let keyboardEndFrame = view.convert(keyboardEndFrameInScreenCoords, from: view.window)
        
        let newBottomInset = requiredScrollViewBottomInset(forKeyboardFrame: keyboardEndFrame)
        let differenceOfBottomInset = newBottomInset - messageCollectionViewBottomInset
        
        if  differenceOfBottomInset > 0 {
            UIView.performWithoutAnimation {
                messageCollectionViewBottomInset = newBottomInset
            }
            
            if mainView.collectionView.contentSize.height >= mainView.collectionView.frame.size.height {
                
                let contentOffset = CGPoint(x: mainView.collectionView.contentOffset.x, y: mainView.collectionView.contentOffset.y + differenceOfBottomInset)

                guard contentOffset.y <= mainView.collectionView.contentSize.height else {
                    return
                }
                mainView.collectionView.setContentOffset(contentOffset, animated: false)
            }
        
        } else {
                messageCollectionViewBottomInset = newBottomInset
        
        }
    }
    
    // MARK: - Inset Computation
    
    private func requiredScrollViewBottomInset(forKeyboardFrame keyboardFrame: CGRect) -> CGFloat {
   
        let intersection = mainView.collectionView.frame.intersection(keyboardFrame)
        
        if intersection.isNull || (mainView.collectionView.frame.maxY - intersection.maxY) > 0.001 {
            // The keyboard is hidden, is a hardware one, or is undocked and does not cover the bottom of the collection view.
            // Note: intersection.maxY may be less than messagesCollectionView.frame.maxY when dealing with undocked keyboards.
            return max(0, additionalBottomInset - automaticallyAddedBottomInset)
        } else {
            return max(0, intersection.height + additionalBottomInset - automaticallyAddedBottomInset)
        }
    }
    
    func requiredInitialScrollViewBottomInset() -> CGFloat {
        let inputAccessoryViewHeight = inputAccessoryView?.frame.height ?? 0
        return max(0, inputAccessoryViewHeight + additionalBottomInset - automaticallyAddedBottomInset)
    }
    
    /// UIScrollView can automatically add safe area insets to its contentInset,
    /// which needs to be accounted for when setting the contentInset based on screen coordinates.
    ///
    /// - Returns: The distance automatically added to contentInset.bottom, if any.
    private var automaticallyAddedBottomInset: CGFloat {
        return mainView.collectionView.adjustedContentInset.bottom - mainView.collectionView.contentInset.bottom
    }
}
