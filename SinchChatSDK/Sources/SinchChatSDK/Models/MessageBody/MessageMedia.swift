import UIKit

public enum TypeMessageMedia: Codable, Equatable, Sendable {
    case image
    case audio
    case video
    case file(FileType?)
    case unsupported
    
}
public enum FileType: String, Codable, Sendable {
    case pdf = "PDF"
    case doc = "DOC"
    case docx = "DOCX"
    case xls = "XLS"
    case xlsx = "XLSX"
    case pptx = "PPTX"
    case ppt = "PPT"
    case gif = "GIF"
    case unknown = ""

    static func getFileType(urlExtension: String) -> FileType? {
        switch urlExtension {
        case "pdf":
            return .pdf
        case "doc":
            return .doc
        case "docx":
        return .docx
        case "xls":
        return .xls
        case "xlsx":
        return .xlsx
        case "pptx":
        return .pptx
        case "ppt":
        return .ppt
        case "gif":
            return .gif
        default:
            return nil
        }
    }
    
}

public struct MessageMedia: MessageBody, MessageWithURL {
    
    public var url: String
    public var savedUrl: String?
    public var sendDate: Int64?
    public var type: TypeMessageMedia?
    public var isExpanded: Bool = false
    public var size: String?

    public init(url: String, sendDate: Int64? = nil, placeholderImage: UIImage? = nil, type: TypeMessageMedia? = nil) {
        self.url = url
        self.sendDate = sendDate
        self.type = type
    }
    
    public func convertStringToImage(strBase64: String) -> UIImage? {
        
        if let data = Data(base64Encoded: strBase64, options: .ignoreUnknownCharacters) {
            return UIImage(data: data)
        } else {
            return nil
        }
    }
}
