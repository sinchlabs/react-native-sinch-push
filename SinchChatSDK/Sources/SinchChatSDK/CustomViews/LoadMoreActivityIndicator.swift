import UIKit

@MainActor
class LoadMoreActivityIndicator {
    
    private let spacingFromLastCell: CGFloat
    private let spacingFromLastCellOnActionStart: CGFloat
    private weak var activityIndicatorView: UIActivityIndicatorView?
    private weak var scrollView: UIScrollView?
    
    private var defaultY: CGFloat {
        guard let height = scrollView?.contentSize.height else { return 0.0 }
        return height + spacingFromLastCell
    }
    
    deinit { activityIndicatorView?.removeFromSuperview() }
    
    init (scrollView: UIScrollView, spacingFromLastCell: CGFloat, spacingFromLastCellOnActionStart: CGFloat) {
        self.scrollView = scrollView
        self.spacingFromLastCell = spacingFromLastCell
        self.spacingFromLastCellOnActionStart = spacingFromLastCellOnActionStart
        let size:CGFloat = 40
        let frame = CGRect(x: (scrollView.frame.width-size)/2, y: scrollView.contentSize.height + spacingFromLastCell, width: size, height: size)
        let activityIndicatorView = UIActivityIndicatorView(frame: frame)
        if #available(iOS 13.0, *) {
            activityIndicatorView.color = .label
        } else {
            activityIndicatorView.color = .black
        }
        activityIndicatorView.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]
        activityIndicatorView.hidesWhenStopped = true
        scrollView.addSubview(activityIndicatorView)
        self.activityIndicatorView = activityIndicatorView
    }
    
    private var isHidden: Bool {
        guard let scrollView = scrollView else { return true }
        return scrollView.contentSize.height < scrollView.frame.size.height
    }
    
    func start(closure: (() -> Void)?) {
        guard let scrollView = scrollView, let activityIndicatorView = activityIndicatorView else { return }
        let offsetY = scrollView.contentOffset.y
        activityIndicatorView.isHidden = isHidden
        if !isHidden && offsetY >= 0 {
            let contentDelta = scrollView.contentSize.height - scrollView.frame.size.height
            let offsetDelta = offsetY - contentDelta
            
            let newY = defaultY-offsetDelta
            if newY < scrollView.frame.height {
                activityIndicatorView.frame.origin.y = newY
            } else {
                if activityIndicatorView.frame.origin.y != defaultY {
                    activityIndicatorView.frame.origin.y = defaultY
                }
            }
            
            if !activityIndicatorView.isAnimating {
                if offsetY > contentDelta && offsetDelta >= spacingFromLastCellOnActionStart && !activityIndicatorView.isAnimating {
                    activityIndicatorView.startAnimating()
                    closure?()
                }
            }
            
            if scrollView.isDecelerating {
                if activityIndicatorView.isAnimating && scrollView.contentInset.bottom == 0 {
                    let bottomInset = spacingFromLastCellOnActionStart
                    UIView.animate(withDuration: 0.3) { [weak self] in
                        if self != nil {
                            scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
                        }
                    }
                }
            }
        }
    }
    
    func stop(completion: (() -> Void)? = nil) {
        guard let scrollView = scrollView, let activityIndicatorView = activityIndicatorView else { return }
        let contentDelta = scrollView.contentSize.height - scrollView.frame.size.height
        let offsetDelta = scrollView.contentOffset.y - contentDelta
        if offsetDelta >= 0 {
            UIView.animate(withDuration: 0.3, animations: { [weak scrollView] in
                scrollView?.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            }) { _ in
                completion?()
            }
        } else {
            scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            completion?()
        }
        activityIndicatorView.stopAnimating()
    }
}
