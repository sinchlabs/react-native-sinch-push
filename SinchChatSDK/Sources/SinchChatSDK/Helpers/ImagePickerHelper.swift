import UIKit
import AVFoundation
import Photos
import MobileCoreServices

@MainActor
public protocol ImagePickerDelegate: AnyObject {
    func didSelect(image: UIImage?)
    func didSelect(video: URL?)

}

@MainActor
final class ImagePickerHelper: NSObject {

    private var pickerController: UIImagePickerController = UIImagePickerController()
    private weak var presentationController: UIViewController?
    private weak var delegate: ImagePickerDelegate?
    
    public init(presentationController: UIViewController, delegate: ImagePickerDelegate) {
        
        super.init()
        
        self.presentationController = presentationController
        self.delegate = delegate
        pickerController.delegate = self
        pickerController.allowsEditing = true
        pickerController.sourceType = .photoLibrary
        pickerController.presentationController?.delegate = self
    }
    
    func pickPhotoFromGallery() {
        if UIImagePickerController.isSourceTypeAvailable(.photoLibrary) {
            var mediaTypes: [String] = []
            if !SinchChatSDK.shared.disabledFeatures.contains(.sendImageMessageFromGallery) {
                mediaTypes.append(kUTTypeImage as String)
            }
            if !SinchChatSDK.shared.disabledFeatures.contains(.sendVideoMessageFromGallery) {
                mediaTypes.append(contentsOf: [kUTTypeMovie as String, kUTTypeVideo as String, kUTTypeMPEG4 as String])
            }
            pickerController.mediaTypes = mediaTypes
            
            self.pickerController.videoMaximumDuration = 15
            self.pickerController.sourceType = .photoLibrary

            self.presentationController?.present(self.pickerController, animated: true, completion: {
                if let presentationController = self.presentationController as? StartViewController {
                    presentationController.removeKeyboardObservers()
                }
            })
        }
    }
    
    func takePhoto(completion: @escaping (_ success:Bool) -> Void ) {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            
            pickerController.sourceType = .camera
            var mode: UIImagePickerController.CameraCaptureMode = .photo
        
            var mediaTypes: [String] = []
            if !SinchChatSDK.shared.disabledFeatures.contains(.sendImageFromCamera) {
                mediaTypes.append(kUTTypeImage as String)
            }
            if !SinchChatSDK.shared.disabledFeatures.contains(.sendVideoMessageFromCamera) {
                mediaTypes.append(contentsOf: [kUTTypeMovie as String, kUTTypeVideo as String, kUTTypeMPEG4 as String])
                if SinchChatSDK.shared.disabledFeatures.contains(.sendImageFromCamera) {
                    mode = .video

                }
            }
            
            pickerController.mediaTypes = mediaTypes
            pickerController.cameraCaptureMode = mode
            
            AVCaptureDevice.requestAccess(for: AVMediaType.video,
                                          completionHandler: { (granted:Bool) -> Void in
                if granted {
                    
                    DispatchQueue.main.async {
                        self.presentationController?.present(self.pickerController, animated: true)
                    }
                    completion(true)
                } else {
                    completion(false)
                }
            })
        } else {
            completion(false)
        }
    }
    
    private func pickerController(_ controller: UIImagePickerController, didSelect image: UIImage?) {
        controller.dismiss(animated: true, completion: nil)
        delegate?.didSelect(image: image)
        self.presentationController?.inputAccessoryView?.isHidden = false

    }
    private func pickerController(_ controller: UIImagePickerController, didSelectVideo video: URL) {
        
        controller.dismiss(animated: true, completion: nil)
        self.presentationController?.inputAccessoryView?.isHidden = false

        delegate?.didSelect(video: video)

    }
}
extension ImagePickerHelper: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    
    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        pickerController(picker, didSelect: nil)
        self.presentationController?.inputAccessoryView?.isHidden = false

    }
    
    public func imagePickerController(_ picker: UIImagePickerController,
                                      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        
        if let image = info[.editedImage] as? UIImage {
            pickerController(picker, didSelect: image)

        } else if let url = info[.mediaURL] as? URL {
         
            self.pickerController(picker, didSelectVideo: url)
            
        } else {
                pickerController(picker, didSelect: nil)
        }
    }
}
extension ImagePickerHelper: UIAdaptivePresentationControllerDelegate {
   
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        print("The dismissal animation finished after the user swiped down.")
        self.presentationController?.inputAccessoryView?.isHidden = false
        delegate?.didSelect(image: nil)
        // This is probably where you want to put your code that you want to call.
    }
}
