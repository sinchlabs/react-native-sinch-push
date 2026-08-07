import Kingfisher
import UIKit

extension UIImageView {
    func setImage(url: URL) {
        kf.setImage(with: url)
    }

    func setImage(url: URL, completion: @escaping (Result<RetrieveImageResult, KingfisherError>) -> Void) {

        kf.indicatorType = .none
        kf.setImage(with: url) { result in
            completion(result)
        }
    }
    func setImage(provider: AVAssetImageDataProvider, completion: @escaping (Result<RetrieveImageResult, KingfisherError>) -> Void) {

        kf.indicatorType = .none
        kf.setImage(with: provider) { result in
            completion(result)
        }
    }
}
