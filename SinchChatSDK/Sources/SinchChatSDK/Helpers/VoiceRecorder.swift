import Foundation
import AVFoundation

@MainActor
protocol VoiceRecordingProtocol: AnyObject {
    func updateTime(_ duration: Double)
    func recordingStarted(_ duration: Double, url: URL)
    func recordingContinued(_ duration: Double, url: URL)
    func recordingFinished(_ duration: Double, url: URL)
    func errorSavingVoiceMessage(text: String)
    func doNotHaveMicrophoneAccess()
    func successfullySavedVoiceMessage(url: URL)
    
}

nonisolated(unsafe) var recordingSession: AVAudioSession!

@MainActor
final class VoiceRecorderController: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    
    nonisolated(unsafe) var recordingSession: AVAudioSession!
    weak var delegate: VoiceRecordingProtocol?
    var audioRecorder: AVAudioRecorder?
    var audioPlayer: AVAudioPlayer = AVAudioPlayer()
    var isRecording = false
    var isCanceled = false
    var duration = 0.0
    nonisolated(unsafe) var timer: Timer?
    var startTime: Date?
    var shouldRecord = true
    
    override init() {
        super.init()
        recordingSession = AVAudioSession.sharedInstance()
        if let fileURL = Bundle.staticBundle.path(forResource: "record", ofType: "wav") {
            
            do {
                
                audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: fileURL))
                audioPlayer.delegate = self
                
            } catch {
                
            }
        }
    }
    deinit {
        timer?.invalidate()
        timer = nil
    }
    
    func startRecordingSession() {
        shouldRecord = true
        
        do {
            
            try recordingSession.setCategory(.playAndRecord, mode: .default)
            try recordingSession.setActive(true)
            recordingSession.requestRecordPermission { [weak self] allowed in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    if allowed {
                        if self.shouldRecord {
                            self.isRecording = true
                            self.isCanceled = false
                            self.audioPlayer.play()
                        }
                        
                    } else {
                        
                        self.delegate?.doNotHaveMicrophoneAccess()
                    }
                }
            }
        } catch {
            debugPrint("Error")
            
            delegate?.errorSavingVoiceMessage(text:"Error")
        }
    }
    
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if self.isRecording {
                self.startRecording()
                if let audioRecorder = self.audioRecorder {

                    self.delegate?.recordingStarted(self.duration, url: audioRecorder.url)
                }
            }
        }
    }
    
    func startRecording() {
        
        startTime = Date()
        isRecording = true
        let audioFilename = getDocumentsDirectory().appendingPathComponent("recording.mp4")
        
        let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 11025,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            timer = Timer.scheduledTimer(timeInterval: 0.5, target: self,
                                         selector: #selector(onTimerFires), userInfo: nil, repeats: true)
            timer?.tolerance = 0.1
            
        } catch {
            isRecording = false
            delegate?.errorSavingVoiceMessage(text: "Error")
        }
    }
    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
    @objc func onTimerFires() {
        duration += 0.5
        if floor(duration) == duration {
            delegate?.updateTime(duration)
        }
        
    }
    
    func finishRecording() {
        
        if !isRecording {
            isCanceled = true
            
            finishRecordingAction()
        } else {
            finishRecordingAction()
            
        }
        
    }
    func finishRecordingAction() {
        
        if let startTime = startTime {
            let components = Calendar.current.dateComponents([.second], from:  startTime, to: Date())
            if let second = components.second, let audioRecorder = audioRecorder {
                
                delegate?.recordingFinished(Double(second), url: audioRecorder.url)
            }
        } else {
            if let audioRecorder = audioRecorder {
                
                delegate?.recordingFinished(duration, url: audioRecorder.url)
            }
            
        }
        
        isRecording = false
        if audioRecorder != nil {
            audioRecorder?.stop()
            
        }
        if timer != nil {
            timer?.invalidate()
        }
        startTime = nil
        
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            debugPrint("end recording")

            self.isRecording = false
            self.audioPlayer.play()

            if !flag {
                self.finishRecording()
            } else if !self.isCanceled {
                self.delegate?.successfullySavedVoiceMessage(url: url)

            }
        }
    }
    func continueRecording() {
        
        if isRecording {
            
            timer?.invalidate()
            audioRecorder?.stop()
            isRecording = false
        } else {
            timer = Timer.scheduledTimer(timeInterval: 1.0,
                                         target: self,
                                         selector: #selector(onTimerFires), userInfo: nil, repeats: true)
            timer?.tolerance = 0.1
            isRecording = true
            audioRecorder?.record()
            if let audioRecorder = audioRecorder {
                
                delegate?.recordingContinued(duration, url: audioRecorder.url)
            }
        }
    }
    
    func removeRecording() {
        var _ =  audioRecorder?.deleteRecording()
        
        audioRecorder = nil
        timer = nil
        duration = 0.0
        startTime = nil
        
    }
}
