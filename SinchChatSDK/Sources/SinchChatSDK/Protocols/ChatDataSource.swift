import UIKit

@MainActor
protocol ChatDataSource: AnyObject {
    
    /// A helper method to determine if a given message is from the current `SenderType`.
    ///
    /// - Parameters:
    ///   - message: The message to check if it was sent by the current `SenderType`.
    ///
    /// - Note:
    ///   The default implementation of this method checks for equality between
    ///   the message's `SenderType` and the current `SenderType`.
    func isFromCurrentSender(message: Message) -> Bool
    
    /// The message to be used for a `MessageCollectionViewCell` at the given `IndexPath`.
    ///
    /// - Parameters:
    ///   - indexPath: The `IndexPath` of the cell.
    ///   - messagesCollectionView: The `MessagesCollectionView` in which the message will be displayed.
    func messageForItem(at indexPath: IndexPath, in messagesCollectionView: MessageCollectionView) -> Message
    
    /// The number of sections to be displayed in the `MessageCollectionView`.
    ///
    /// - Parameters:
    ///   - messagesCollectionView: The `MessagesCollectionView` in which the messages will be displayed.
    func numberOfSections(in messagesCollectionView: MessageCollectionView) -> Int
    
    /// The number of cells to be displayed in the `MessagesCollectionView`.
    ///
    /// - Parameters:
    ///   - section: The number of the section in which the cells will be displayed.
    ///   - messagesCollectionView: The `MessagesCollectionView` in which the messages will be displayed.
    /// - Note:
    ///   The default implementation of this method returns 1. Putting each message in its own section.
    func numberOfItems(inSection section: Int, in messagesCollectionView: MessageCollectionView) -> Int
    
}

extension ChatDataSource {
    
    func isFromCurrentSender(message: Message) -> Bool {
        switch  message.owner {
        case .outgoing:
            return true
        default:
            return false
        }
    }
    
    func numberOfItems(inSection section: Int, in messagesCollectionView: MessageCollectionView) -> Int {
        return 1
    }
}
