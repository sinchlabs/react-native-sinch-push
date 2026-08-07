import Foundation

public struct SinchSDKConfig: Sendable {
    private let appConfig: AppConfig

    public init(appConfig: AppConfig) {
        self.appConfig = appConfig
    }

    public struct AppConfig: Codable, Sendable {
        // swiftlint:disable:next type_name nesting
        typealias ID = String

        let clientID: ID
        let projectID: ID
        let configID: ID
        let region: Region
        let locale: Locale

        public init(clientID: String, projectID: String, configID: String, region: Region, locale: Locale = Locale.current) {
            self.clientID = clientID
            self.projectID = projectID
            self.configID = configID
            self.region = region
            self.locale = locale
        }
    }
}
