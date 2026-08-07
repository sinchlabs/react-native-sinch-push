import UIKit

final class ImageProcessor {
    private let image: UIImage

    init(_ image: UIImage) {
        self.image = image
    }
    
    func convertImageToString() -> String? {
    
        let imageData = image.jpegData(compressionQuality: 0.8)
        let strBase64 = imageData?.base64EncodedString(options: .lineLength64Characters)
        
       return strBase64
    }
    func getImage() -> UIImage {
        return image
    }
}
