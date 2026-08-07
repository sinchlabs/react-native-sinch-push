import Foundation

final class PushDeviceTokenCoordinator {
    private static let deviceTokenKey = "sinch_device_token"
    private static let sentTokenDictionaryKey = "sinch_sent_token_dictionary"

    private let userDefaults: UserDefaults
    
    var authDataSource: AuthDataSource?
    
    private var tokenToSend: String? {
        get { userDefaults.string(forKey: PushDeviceTokenCoordinator.deviceTokenKey) }
        set { userDefaults.set(newValue, forKey: PushDeviceTokenCoordinator.deviceTokenKey) }
    }
    
    private var sentTokenDictionary: [String: String] {
        get {
            if let data = userDefaults.data(forKey: PushDeviceTokenCoordinator.sentTokenDictionaryKey) {
                return (try? PropertyListDecoder().decode([String: String].self, from: data)) ?? [:]
            }
            return [:]
        }
        set { userDefaults.set(try? PropertyListEncoder().encode(newValue), forKey: PushDeviceTokenCoordinator.sentTokenDictionaryKey) }
    }
    
    init(userDefaults: UserDefaults = UserDefaults.standard) {
        self.userDefaults = userDefaults
    }
    
    func setTokenToSend(deviceToken: Data) {
        tokenToSend = deviceToken.hexEncodedString()
    }
    
    func getLastToken() -> String? {
        guard let token = tokenToSend else {
            return nil
        }
        
        return token
    }
    
    func getTokenToSend() -> String? {
        guard let token = tokenToSend, let identityHash = authDataSource?.identityHashValue else {
            return nil
        }
    
        if sentTokenDictionary[identityHash] == token {
            return nil
        }
        
        return token
    }
    
    func tokenDidSent() {
        guard let identityHash = authDataSource?.identityHashValue, let token = tokenToSend else {
            return
        }
        
        sentTokenDictionary[identityHash] = token
    }
}
