import UIKit
import Network

final class InboxViewController: SinchViewController<InboxViewModel, InboxView>, SinchChatViewController, InboxViewModelDelegate {
    
    var customOptions: GetChatViewControllerOptions =  .init(metadata: [], shouldInitializeConversation: true)
    
    lazy var activityIndicator = LoadMoreActivityIndicator(scrollView: mainView.tableView, spacingFromLastCell: 10, spacingFromLastCellOnActionStart: 60)
    let monitor = NWPathMonitor()

    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.title = mainView.localizationConfiguration.inboxNavigationBarText
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
        mainView.tableView.delegate = self
        mainView.tableView.dataSource = self
        addNoInternetObservers()

        (viewModel as? DefaultInboxViewModel)?.delegate = self
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        setNavigationBarStyle(uiConfig: mainView.uiConfig)
        addStartConversationButton()
      
        if isModal {
            addCloseButton()
        } else {
            addBackButton()
        }
        
    }
    
    deinit {
        let viewModel = self.viewModel
        let monitor = self.monitor
        Task { @MainActor in
            viewModel.setIdleState()
            viewModel.closeChannel()
        }
        monitor.cancel()

    }
    private func addStartConversationButton() {
        
        let startConversationButton = UIButton(type: .custom)
        startConversationButton.setImage(mainView.uiConfig.inboxStartConversationImage, for: .normal)
        startConversationButton.addTarget(self, action: #selector(startConversationAction), for: .touchUpInside)

        let rightBarButton = UIBarButtonItem(customView: startConversationButton)
        navigationItem.rightBarButtonItem = rightBarButton
        
    }
    @objc func startConversationAction() {
        showChat()
    }
    
    func addNoInternetObservers() {
        
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { [weak self] in
                if path.status == .satisfied {
                    self?.viewModel.setInternetConnectionState(.isOn)
                } else {
                    self?.viewModel.setInternetConnectionState(.isOff)
                }
            }
        }
        let queue = DispatchQueue(label: "internetConnectionMonitor")
        monitor.start(queue: queue)
    }
    
    func didChangeInternetState(_ state: InternetConnectionState) {
        switch state {
            
        case .isOn:
            debugPrint("ON ***********")
                    
            viewModel.onInternetOn()
            
        case .isOff:
            debugPrint("OFF ***********")

            viewModel.onInternetLost()
            
        case .notDetermined:
            break
        }
        
        mainView.setErrorViewState(state)
    }
    
    func didUpdateChannels(_ channels: [Sinch_Chat_Sdk_V1alpha2_Channel]) {

        debugPrint("didUpdateChannels")
        mainView.tableView.reloadData()
        self.activityIndicator.stop()

    }
    
    func didUpdateChannelAtIndex(_ index: Int) {
        debugPrint("didUpdateChannel")
       // if let row = viewModel.channelsArray.firstIndex(where: { $0.channelID == channel.channelID }) {
        mainView.tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
        
    }
    func moveChannelToTopFromIndex(_ index: Int) {
        debugPrint("moveChannelToTopFromIndex")

        mainView.tableView.beginUpdates()
        mainView.tableView.moveRow(at: IndexPath(row: index, section: 0), to: IndexPath(row: 0, section: 0))
        mainView.tableView.endUpdates()

    }
    func handleError(_ error: Error) {
        debugPrint("handleError")

     //   DispatchQueue.main.async {
            
            self.activityIndicator.stop()
     //   }
    }
}
extension InboxViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return viewModel.channelsArray.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "inboxCell", for: indexPath) as? InboxTableViewCell else {
            return UITableViewCell()
        }
        cell.selectionStyle = .none
        cell.updateWithChannel(viewModel.channelsArray[indexPath.row],
                               uiConfig: mainView.uiConfig,
                               localizationConfig: mainView.localizationConfiguration)
        
        return cell
    }
}
extension InboxViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    
        let channel = viewModel.channelsArray[indexPath.row]
        
        showChatForChannel(channel)
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if self.viewModel.isLoadingMore {
            return
        }
        activityIndicator.start {

            DispatchQueue.global(qos: .utility).async {
                sleep(1)
                Task { @MainActor in
                    self.viewModel.fetchMoreChannels()
                }
            }
        }
    }
    func showChatForChannel(_ channel: Sinch_Chat_Sdk_V1alpha2_Channel) {
        
        customOptions = .init(
            topicID: channel.channelID,
            metadata: customOptions.metadata,
            shouldInitializeConversation: customOptions.shouldInitializeConversation,
            sendDocumentAsTextMessage: customOptions.sendDocumentAsTextMessage
        )

        guard let chatViewController = (try? SinchChatSDK.shared.chat.getChatViewController(
            uiConfig: mainView.uiConfig,
            localizationConfig: mainView.localizationConfiguration,
            options: customOptions)
        ) as? StartViewController else {
            return
        }
        chatViewController.viewModel.isStartedFromInbox = true
        
        self.navigationController?.pushViewController(chatViewController, animated: true)
    }
    
    func showChat() {
        
        if let userID = viewModel.authDataSource.currentAuthorization?.getUserID() {
            customOptions.topicID = "\(UUID().uuidString)"
        }
        
        guard let chatViewController = (try? SinchChatSDK.shared.chat.getChatViewController(
            uiConfig: mainView.uiConfig,
            localizationConfig: mainView.localizationConfiguration,
            options: customOptions)
        ) as? StartViewController else {
            return
        }
        chatViewController.viewModel.isStartedFromInbox = true
        customOptions.topicID = nil
        
        self.navigationController?.pushViewController(chatViewController, animated: true)
    }
    
}
