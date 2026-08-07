import Foundation
import UIKit
@MainActor
protocol InboxViewModel {
    
    var delegate: InboxViewModelDelegate? { get }
    var apiClient: APIClient { get }
    var authDataSource: AuthDataSource { get }
    var channelsArray: [Sinch_Chat_Sdk_V1alpha2_Channel] { get }
    var isLoadingMore: Bool { get }

    //    func onWillEnterForeground()
    //    func onDidEnterBackground()
    func onInternetLost()
    func onInternetOn()
    func setIdleState()
    func closeChannel()
    func setInternetConnectionState(_ state: InternetConnectionState)
    func fetchMoreChannels()
    
}
@MainActor
protocol InboxViewModelDelegate: AnyObject {
    func didChangeInternetState(_ state: InternetConnectionState)
    func didUpdateChannels(_ channels: [Sinch_Chat_Sdk_V1alpha2_Channel])
    func didUpdateChannelAtIndex(_ index: Int)
    func moveChannelToTopFromIndex(_ index: Int)
    func handleError(_ error: Error)

}

@MainActor
final class DefaultInboxViewModel: InboxViewModel, @unchecked Sendable {

    weak var delegate: InboxViewModelDelegate?
    private let pushPermissionHandler: PushNofiticationPermissionHandler
    var apiClient: APIClient
    var authDataSource: AuthDataSource
    var dataSource: DefaultInboxDataSource // todo protocol
    var channelsArray: [Sinch_Chat_Sdk_V1alpha2_Channel] = []
    var firstPage: Bool = true
    var error: Error?
    var isLoadingMore: Bool = false
    
    var state: InternetConnectionState = .notDetermined {
        willSet {
            if state != newValue {
                
                delegate?.didChangeInternetState(newValue)
                
            }
        }
    }
    
    init(pushPermissionHandler: PushNofiticationPermissionHandler, apiClient: APIClient, authDataSource: AuthDataSource) {
        self.pushPermissionHandler = pushPermissionHandler
        self.apiClient = apiClient
        self.authDataSource = authDataSource
        self.dataSource = DefaultInboxDataSource(apiClient:  self.apiClient, authDataSource:  self.authDataSource)
        dataSource.delegate = self
    }
    
    func closeChannel() {
        dataSource.closeChannel()
    }
    
    func onInternetOn() {
        if !channelsArray.isEmpty {
            channelsArray = []
            delegate?.didUpdateChannels(self.channelsArray)
            
        }
        
        dataSource.cancelCalls()
        setRunningState()
        
    }
    func onInternetLost() {
        dataSource.cancelSubscription()
        error = nil
    }
    
    func onWillEnterForeground() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
            self.dataSource.startChannel()
            self.setRunningState()
            
        })
    }
    
    func onDidEnterBackground() {
        setIdleState()
        dataSource.closeChannel()
        
    }
    
    func setIdleState() {
        dataSource.cancelSubscription()
        
        channelsArray = []
        delegate?.didUpdateChannels(self.channelsArray)
        firstPage = true

        error = nil
        // SinchChatSDK.shared._chat.state = .idle
    }
    
    private func setRunningState() {
        
        // SinchChatSDK.shared._chat.state = .running
        getChannels()
        subscribeForChannels()
        
    }
    func fetchMoreChannels() {
        isLoadingMore = true
         getChannels()
    }
    func getChannels() {
        
        dataSource.getChannels { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch result {
                case .success(let channels):
                    if self.channelsArray.isEmpty {
                        self.channelsArray = channels
                    } else {
                        let filteredChannels = channels.filter { channel in
                            self.channelsArray.firstIndex(where: { $0.channelID == channel.channelID }) == nil
                        }
                        self.channelsArray.append(contentsOf: filteredChannels)
                    }
                    self.isLoadingMore = false
                    self.delegate?.didUpdateChannels(self.channelsArray)

                case .failure(let error):
                    self.isLoadingMore = false
                    Logger.verbose(error)
                    self.error = error
                    self.delegate?.handleError(error)
                }
            }
        }
    }
    
    func subscribeForChannels() {
        dataSource.subscribeForChannels { [weak self] result in
            
            guard let self = self else {
                return
            }
            
            switch result {
            case .success(let channel):
                let channelID = channel.channelID
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    debugPrint(channelID)
                    debugPrint(self.channelsArray.contains(channel))
                    if self.channelsArray.isEmpty {
                        self.channelsArray.append(channel)
                        self.delegate?.didUpdateChannels(self.channelsArray)
                    } else if let row = self.channelsArray.firstIndex(where: { $0.channelID == channel.channelID }) {
                        var channelToUpdate = self.channelsArray[row]
                        channelToUpdate.updateChannel(channel: channel)
                        self.channelsArray[row] = channelToUpdate
                        self.delegate?.didUpdateChannelAtIndex(row)
                        self.channelsArray.move(from: row, to: 0)
                        self.delegate?.moveChannelToTopFromIndex(row)
                    } else {
                        self.channelsArray = []
                        self.delegate?.didUpdateChannels(self.channelsArray)
                        self.dataSource.resetPagination()
                        self.getChannels()
                    }
                }

            case .failure(let error):
                let nsError = error
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    Logger.verbose(nsError)
                    self.error = nsError
                }
            }
        }
    }
    func setInternetConnectionState(_ state: InternetConnectionState) {
        self.state = state
    }
}
extension Sinch_Chat_Sdk_V1alpha2_Channel {
    
    mutating func updateChannel(channel: Sinch_Chat_Sdk_V1alpha2_Channel) {
        
        if !channel.displayName.isEmpty {
            self.displayName = channel.displayName
        }
        
        if channel.hasLastEntry {
            self.lastEntry = channel.lastEntry
        }
        
        if !channel.users.isEmpty {
            self.users = channel.users
        }
        
        if channel.hasSeenAt {
            self.seenAt = channel.seenAt
        }
        if channel.hasCreatedAt {
            self.createdAt = channel.createdAt
        }
        if channel.hasUpdatedAt {
            self.updatedAt = channel.updatedAt
        }
        if channel.hasExpiredAt {
            self.expiredAt = channel.expiredAt
        }
    }
}
extension DefaultInboxViewModel: InboxDataSourceDelegate {

    nonisolated func subscriptionError() {
        Task { @MainActor [weak self] in
            self?.subscribeForChannels()
        }
    }
}
extension Array {
    mutating func move(from oldIndex: Index, to newIndex: Index) {
        // Don't work for free and use swap when indices are next to each other - this
        // won't rebuild array and will be super efficient.
        if oldIndex == newIndex { return }
        if abs(newIndex - oldIndex) == 1 { return self.swapAt(oldIndex, newIndex) }
        self.insert(self.remove(at: oldIndex), at: newIndex)
    }
}
