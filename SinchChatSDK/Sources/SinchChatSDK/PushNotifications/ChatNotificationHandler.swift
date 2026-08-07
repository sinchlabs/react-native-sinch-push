import Foundation
import UserNotifications

protocol ChatNotificationHandlerDelegate: AnyObject {
    func getChatState() -> SinchChatState
}

final class ChatNotificationHandler: PushNotificationAddressee {
    let id: PushNotificationAddresseeName = .chat

    weak var delegate: ChatNotificationHandlerDelegate?

    func handleNotification(payload: [AnyHashable : Any]) -> IsHandled {
        checkIfNotificationBelongsToUs(payload: payload)
    }

    func handleWillPresentNotification(_ payload: [AnyHashable : Any]) -> UNNotificationPresentationOptions? {
        guard checkIfNotificationBelongsToUs(payload: payload) else {
            return nil
        }

        switch delegate?.getChatState() {
        case .none, .idle:
            return [.badge, .alert]
        case .running:
            guard let topicID = payload["topic_id"] as? String else {
                return []
            }
            if SinchChatSDK.shared._chat.lastChatOptions?.topicID != topicID {
                return [.badge, .alert]
            }
            guard let senderID = payload["sender_id"] as? String,
                  let uuid = payload["uuid"] as? String else {
                return []
            }
            let addressee = SinchChatSDK.shared._chat.lastChatOptions?.metadata.first(where: { $0.getKeyValue().key == "addressee" })?.getKeyValue().value
            if addressee != senderID, addressee != uuid {
                return [.badge, .alert]
            }

            return []
        }
    }

    // MARK: - Private

    private func checkIfNotificationBelongsToUs(payload: [AnyHashable: Any]) -> Bool {
        guard payload["owner"] as? String == "sinch" else {
            return false
        }
        return true
    }
}
// 3 elements
// ▿ 0 : 2 elements
// ▿ key : AnyHashable("type")
// - value : "type"
// - value : message
// ▿ 1 : 2 elements
// ▿ key : AnyHashable("owner")
// - value : "owner"
// - value : sinch
// ▿ 2 : 2 elements
// ▿ key : AnyHashable("aps")
// - value : "aps"
// ▿ value : 1 element
// ▿ 0 : 2 elements
// - key : alert
// ▿ value : 2 elements
// ▿ 0 : 2 elements
// - key : title
// - value : Hello
// ▿ 1 : 2 elements
// - key : body
// - value : Hello
