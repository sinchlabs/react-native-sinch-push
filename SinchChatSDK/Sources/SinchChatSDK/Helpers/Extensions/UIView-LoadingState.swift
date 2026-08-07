import UIKit

extension UIView {

    func showLoadingState(_ backgroundColor: UIColor = .white) {
        guard !subviews.contains(where: { $0 as? LoadingView != nil }) else {
            return
        }
        let view = getLoadingView()
        view.alpha = 0
        view.backgroundColor = backgroundColor

        UIViewPropertyAnimator(duration: 0.3, curve: .easeInOut) {
            view.alpha = 1
        }.startAnimation()
    }

    func hideLoadingState() {
        guard let view = subviews.first(where: { $0 as? LoadingView != nil }) else {
            return
        }
        let animator = UIViewPropertyAnimator(duration: 0.3, curve: .easeInOut) {
            view.alpha = 0
        }
        animator.addCompletion { _ in
            view.removeFromSuperview()
        }
        animator.startAnimation()
    }

    private func getLoadingView() -> UIView {
        let view = LoadingView()
        var loadingIndicator: UIActivityIndicatorView
        if #available(iOS 13.0, *) {
            loadingIndicator = UIActivityIndicatorView(style: .medium)
        } else {
            loadingIndicator = UIActivityIndicatorView(style: .gray)
        }
        loadingIndicator.startAnimating()

        addSubview(view)
        view.addSubview(loadingIndicator)

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        return view
    }
}

internal extension UIView {
    
    func fillSuperview() {
        guard let superview = self.superview else {
            return
        }
        translatesAutoresizingMaskIntoConstraints = false
        leftAnchor.constraint(equalTo: superview.leftAnchor).isActive = true
        rightAnchor.constraint(equalTo: superview.rightAnchor).isActive = true
        topAnchor.constraint(equalTo: superview.topAnchor).isActive = true
        bottomAnchor.constraint(equalTo: superview.bottomAnchor).isActive = true
    }
}

private class LoadingView: UIView {}
