@MainActor
protocol InboxRootCoordinator: AnyObject {
    var uiConfiguration: SinchSDKConfig.UIConfig { get }
    var localizationConfiguration: SinchSDKConfig.LocalizationConfig { get }
    var inboxDataSource: InboxDataSource { get }

    func getRootViewController(apiClient: APIClient, options: GetChatViewControllerOptions?) -> InboxViewController

}

@MainActor
final class DefaultInboxRootCoordinator: InboxRootCoordinator {
    
    var uiConfiguration: SinchSDKConfig.UIConfig
    var localizationConfiguration: SinchSDKConfig.LocalizationConfig
    var inboxDataSource: InboxDataSource

    private let pushPermissionHandler: PushNofiticationPermissionHandler
    private let authDataSource: AuthDataSource

    init(uiConfiguration: SinchSDKConfig.UIConfig,
         localizationConfiguration: SinchSDKConfig.LocalizationConfig,
         authDataSource: AuthDataSource,
         pushPermissionHandler: PushNofiticationPermissionHandler,
         inboxDataSource: InboxDataSource) {
        
        self.uiConfiguration = uiConfiguration
        self.localizationConfiguration = localizationConfiguration
        self.inboxDataSource = inboxDataSource
        self.authDataSource = authDataSource
        self.pushPermissionHandler = pushPermissionHandler
    }
    
    func getRootViewController(apiClient: APIClient, options: GetChatViewControllerOptions? = nil) -> InboxViewController {
        
        let inboxViewModel = DefaultInboxViewModel(pushPermissionHandler: pushPermissionHandler, apiClient: apiClient, authDataSource: authDataSource)
        let inboxView = InboxView(uiConfiguration: uiConfiguration, localizationConfiguration: localizationConfiguration)
        
        let inboxViewController = InboxViewController(viewModel: inboxViewModel, view: inboxView)
        
        if let options = options {
            inboxViewController.customOptions = options
        }

        return inboxViewController
    }
}
