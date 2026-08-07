// This is required to build project with GRPC generated files.
@_exported import SwiftProtobuf
import UIKit
import Logging
import GRPCCore
import CoreLocation
import QuickLook

@MainActor
protocol RootCoordinator: AnyObject {
    
    func getRootViewController(uiConfig: SinchSDKConfig.UIConfig, localizationConfig: SinchSDKConfig.LocalizationConfig, sendDocumentAsText: Bool) -> StartViewController
    
    func getMediaViewerController(uiConfig: SinchSDKConfig.UIConfig,
                                  localizationConfig: SinchSDKConfig.LocalizationConfig, url: URL) -> UINavigationController
    
    func getLocationViewController(uiConfig: SinchSDKConfig.UIConfig,
                                   localizationConfig: SinchSDKConfig.LocalizationConfig) -> LocationViewController
    
    func getDocumentViewerController(viewController: StartViewController, cell: UICollectionViewCell,
                                     uiConfig: SinchSDKConfig.UIConfig,
                                     localizationConfig: SinchSDKConfig.LocalizationConfig, url: URL, index: Int) -> PreviewViewController

}

@MainActor
final class DefaultRootCoordinator: RootCoordinator {

    private var messageDataSource: MessageDataSource

    private let pushPermissionHandler: PushNofiticationPermissionHandler
    private let authDataSource: AuthDataSource
    lazy var locationManager = CLLocationManager()

    init(messageDataSource: MessageDataSource,
         authDataSource: AuthDataSource,
         pushPermissionHandler: PushNofiticationPermissionHandler) {
        
        self.messageDataSource = messageDataSource
        self.authDataSource = authDataSource
        self.pushPermissionHandler = pushPermissionHandler
    }
    
    func getRootViewController(
        uiConfig: SinchSDKConfig.UIConfig,
        localizationConfig: SinchSDKConfig.LocalizationConfig,
        sendDocumentAsText: Bool = false
    ) -> StartViewController {

        let startViewModel: StartViewModel = DefaultStartViewModel(
            messageDataSource: messageDataSource,
            notificationPermission: pushPermissionHandler,
            sendDocumentAsText: sendDocumentAsText
        )
        messageDataSource.delegate = startViewModel
        let startViewController = StartViewController(viewModel: startViewModel, view: .init(uiConfiguration: uiConfig, localizationConfiguration: localizationConfig))
        startViewController.cordinator = self
        return startViewController
    }
    
    func getMediaViewerController(uiConfig: SinchSDKConfig.UIConfig,
                                  localizationConfig: SinchSDKConfig.LocalizationConfig, url: URL) -> UINavigationController {
        
        let mediaViewController = MediaViewerController(
            viewModel: DefaultMediaViewerViewModel(url: url),
            view: .init(uiConfiguration: uiConfig, localizationConfiguration: localizationConfig))
        
        let mediaNavigationController = UINavigationController(rootViewController: mediaViewController)
        mediaNavigationController.modalPresentationStyle = .fullScreen
        mediaNavigationController.modalTransitionStyle = .crossDissolve
        
        return mediaNavigationController
    }
    func getDocumentViewerController(viewController: StartViewController, cell: UICollectionViewCell,
                                     uiConfig: SinchSDKConfig.UIConfig,
                                     localizationConfig: SinchSDKConfig.LocalizationConfig, url: URL, index: Int) -> PreviewViewController {
        
        let quickLookViewController = PreviewViewController()
        quickLookViewController.uiConfig = uiConfig
        quickLookViewController.localizationConfiguration = localizationConfig
        quickLookViewController.dataSource = viewController
        quickLookViewController.delegate = viewController
        quickLookViewController.currentPreviewItemIndex = index
        
        return quickLookViewController
        
    }
    
    func getLocationViewController(uiConfig: SinchSDKConfig.UIConfig, localizationConfig: SinchSDKConfig.LocalizationConfig) -> LocationViewController {

        let locationViewController = LocationViewController(
            viewModel: DefaultLocationViewModel(),
            view: .init(uiConfiguration: uiConfig, localizationConfiguration: localizationConfig))
        locationViewController.locationManager = locationManager
        locationViewController.modalPresentationStyle = .fullScreen
        locationViewController.modalTransitionStyle = .crossDissolve
        
        return locationViewController
    }
}
