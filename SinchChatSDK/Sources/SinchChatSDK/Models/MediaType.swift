import UIKit
import AVFoundation
import MobileCoreServices

enum MediaType: @unchecked Sendable {
    case image(UIImage)
    case video(URL)
    case audio(URL)
    case file(URL,FileType?)
    
    var convertToSinchMedia: Sinch_Chat_Sdk_V1alpha2_UploadMediaRequest? {
        var request = Sinch_Chat_Sdk_V1alpha2_UploadMediaRequest()
        var data: Data?
        var mimeType: String
        var fileName: String?
        
        switch self {
        case .image(let image):
            data = image.jpegData(compressionQuality: 0.8)
            mimeType = "image/jpg"
            
        case .audio(let url):
            do {
                data =  try Data(contentsOf: url)
                mimeType = "audio/mp4"
            
            } catch {
                mimeType = "audio/mp4"
            }
        case .video(let url):
            do {
                data =  try Data(contentsOf: url)
                mimeType = "video/mp4"
            
            } catch {
                mimeType = "video/mp4"
            }
        case .file(let url, let type ):
            do {
                data =  try Data(contentsOf: url)
               
                    let pathExtension = url.pathExtension

                if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, pathExtension as NSString, nil)?.takeRetainedValue(),  let mimetype = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType)?.takeRetainedValue() {
                    mimeType =  mimetype as String
                    fileName = url.lastPathComponent
                } else {
                            mimeType = ""
                            return nil
                }
                            
            } catch {
                mimeType = ""

                return nil
            }
        }
        guard let data = data else { return nil }
        
        let newFilename = fileName?
            .convertToValidFileName()
        
        request.data = data
        request.mimeType = mimeType
        if let newFilename = newFilename {
            request.fileName = newFilename
        }
        
        return request
    }
}

