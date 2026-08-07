import Foundation

public extension Bundle {
    
    static let staticBundle = {
        let candidates = [
            Bundle.main.resourceURL,
            Bundle(for: SinchChatSDK.self).resourceURL
        ]
        
        let bundleName = "SinchChatSDK_SinchChatSDK"
        let bundleNameSecond = "SinchChatSdk-SinchChatSDK_SinchChatSDK"
        
        for candidate in candidates {
            let bundlePath = candidate?.appendingPathComponent(bundleName + ".bundle")
            let bundlePathSecond = candidate?.appendingPathComponent(bundleNameSecond + ".bundle")
            if let bundle = bundlePath.flatMap(Bundle.init(url:)) ?? bundlePathSecond.flatMap(Bundle.init(url:)) {
                return bundle
            }
        }
        
        return Bundle(for: SinchChatSDK.self)
    }()
}
