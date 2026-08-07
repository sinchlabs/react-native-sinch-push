import UIKit
import WebKit

final class FileViewerView: SinchView {
    
    lazy var webview = WKWebView(frame: .zero)
        
    override func setupSubviews() {
        backgroundColor = UIColor(named: "backgroundColor")
        addSubview(webview)
            
    }
    
    override func setupConstraints() {
        webview.translatesAutoresizingMaskIntoConstraints = false
    
        NSLayoutConstraint.activate([
                     
            webview.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            webview.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            webview.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            webview.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)
        ])
    }
}
