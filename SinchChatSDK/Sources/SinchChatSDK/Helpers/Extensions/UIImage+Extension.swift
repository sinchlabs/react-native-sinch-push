import UIKit

extension CGImage {
    var isDark: Bool {
            
            guard let imageData = self.dataProvider?.data else { return false }
            guard let ptr = CFDataGetBytePtr(imageData) else { return false }
            let length = CFDataGetLength(imageData)
            let threshold = Int(Double(self.width * self.height) * 0.45)
            var darkPixels = 0
            for counter in stride(from: 0, to: length, by: 4) {
                let red = ptr[counter]
                let green = ptr[counter + 1]
                let blue = ptr[counter + 2]
                let luminance = (0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue))
                if luminance < 150 {
                    darkPixels += 1
                    if darkPixels > threshold {
                        return true
                    }
                }
            }
            return false
    }
}

extension UIImage {
    var isDark: Bool {

            let rightHigh = CGRect(x: self.size.width - self.size.width / 4,
                                   y: 0, width: self.size.width / 4,
                                   height: self.size.height / 4)
            let rightHQ = self.cgImage?.cropping(to: rightHigh)
            return rightHQ?.isDark ?? false
        
    }
}
