import Foundation
/// A protocol used by `MessageContentCell` subclasses to detect taps in the cell's subviews.
@MainActor
protocol MessageCellDelegate: MessageLabelDelegate {

    func didTapMedia(with url: URL)
    func didTapOnVideo(with url: URL, message: Message)
    func didTapOutsideOfContent(in cell: MessageCollectionViewCell)
    func didTapOutsideOfContent()
    func didTapOnChoice(_ text: ChoiceMessageType, in cell: MessageCollectionViewCell)
    func didTapOnResend(message: Message, in cell: MessageCollectionViewCell)
    func didTapOnFile(url: String, in cell: MessageCollectionViewCell)

}
