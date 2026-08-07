import UIKit
final class MediaViewerView: SinchView {
    
    lazy var zoomingScrollView: UIScrollView = {
        let scrollView = UIScrollView(frame: self.bounds)
        scrollView.backgroundColor = uiConfig.backgroundColor
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator = true
        scrollView.flashScrollIndicators()
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 3.0
        
        if #available(iOS 11.0, *) {
            scrollView.contentInsetAdjustmentBehavior = .never
        }
        
        return scrollView
    }()
    
    lazy var imageView: UIImageView = {
        let view = UIImageView(frame: UIScreen.main.bounds)
        view.backgroundColor = uiConfig.backgroundColor
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        
        return view
    }()
        
    override func setupSubviews() {
        backgroundColor = uiConfig.backgroundColor
        zoomingScrollView.addSubview(imageView)
        addSubview(self.zoomingScrollView)
    }
    
    override func setupConstraints() {
        zoomingScrollView.translatesAutoresizingMaskIntoConstraints = false
        zoomingScrollView.fillSuperview()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
      
        let top = imageView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor)
        let bottom = imageView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)
        let leading = imageView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor)
        let trailing = imageView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor)
        
        NSLayoutConstraint.activate([top,
                                     bottom,
                                     trailing,
                                     leading])
    }
}
