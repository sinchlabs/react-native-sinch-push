import Foundation
import AVFoundation

final class VideoProcessor {
    
    private let videoUrl: URL
    var exportSession: AVAssetExportSession?

    init(_ url: URL) {
        self.videoUrl = url
    }
    
    func convertVideoToMP4(completion: @escaping (URL?) -> Void) {

        let avAsset = AVURLAsset(url: videoUrl, options: nil)
        let startDate = Foundation.Date()
        
        exportSession = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetPassthrough)

        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] as URL

        let filePath = documentsDirectory.appendingPathComponent("rendered-Video.mp4")
        deleteFile(filePath)
        
        exportSession!.outputURL = filePath
        exportSession!.outputFileType = AVFileType.mp4
        exportSession!.shouldOptimizeForNetworkUse = true
        let start = CMTimeMakeWithSeconds(0.0, preferredTimescale: 0)
        let range = CMTimeRangeMake(start: start, duration: avAsset.duration)
        exportSession!.timeRange = range

        exportSession!.exportAsynchronously(completionHandler: {() -> Void in
            switch self.exportSession!.status {
            case .failed:
                debugPrint("%@", self.exportSession?.error)
                completion(nil)
            case .cancelled:
                completion(nil)
            case .completed:
                // Video conversion finished
                let endDate = Foundation.Date()
                let time = endDate.timeIntervalSince(startDate)
                debugPrint(time)
                debugPrint("Successful!")
                debugPrint(self.exportSession?.outputURL)
                completion(self.exportSession?.outputURL)
         
            default:
                completion(nil)

            }
        })
    }

    func deleteFile(_ filePath:URL) {
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return
        }
        
        do {
            try FileManager.default.removeItem(atPath: filePath.path)
        } catch {
            debugPrint("Unable to delete file: \(error)")
        }
    }
}
