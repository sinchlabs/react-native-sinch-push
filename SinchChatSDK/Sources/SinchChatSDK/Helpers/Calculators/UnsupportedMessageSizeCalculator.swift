import UIKit

final class UnsupportedMessageSizeCalculator: TextMessageSizeCalculator {
    
    override func messageLabelSize(for message: Message) -> CGSize {
        let maxWidth = messageContainerMaxWidth(for: message)
        
        var messageLabelSize: CGSize = .zero
        let attributedText: NSAttributedString
        var text: String = ""
        
        if let layout = layout as? ChatFlowLayout {
            text = layout.messagesCollectionView.localizationConfig.unsupportedMessageExplanation
        }
        
        attributedText = NSAttributedString(string: text, attributes: [.font: messageLabelFont])
        messageLabelSize = labelSize(for: attributedText, considering: maxWidth)

        if message.body.sendDate != nil {
            messageLabelSize.height += messageLabelInsets.top
            messageLabelInsets.bottom = 0
        } else {
            messageLabelInsets.bottom = 8
            
            messageLabelSize.height += (messageLabelInsets.top + messageLabelInsets.bottom)
        }
        
        messageLabelSize.width += (messageLabelInsets.right + messageLabelInsets.left)
        return messageLabelSize
    }
}
