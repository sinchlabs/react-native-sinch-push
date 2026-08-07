//
//  AudioSessionController.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 19/03/2018.
//

import Foundation
import AVFoundation

public enum InterruptionType: Equatable {
    case began
    case ended(shouldResume: Bool)
}

@MainActor
public protocol AudioSessionControllerDelegate: AnyObject {
    func handleInterruption(type: InterruptionType)
}

/**
 Simple controller for the `AVAudioSession`. If you need more advanced options, just use the `AVAudioSession` directly.
 - warning: Do not combine usage of this and `AVAudioSession` directly, chose one.
 */
@MainActor
public class AudioSessionController {
        
    private let audioSession: AudioSession
    private let notificationCenter: NotificationCenter = NotificationCenter.default
    private var _isObservingForInterruptions: Bool = false
    
    /**
     True if another app is currently playing audio.
     */
    public var isOtherAudioPlaying: Bool {
        audioSession.isOtherAudioPlaying
    }
    
    /**
     True if the audiosession is active.
     
     - warning: This will only be correct if the audiosession is activated through this class!
     */
    public var audioSessionIsActive: Bool = false
    
    /**
     Wheter notifications for interruptions are being observed or not.
     This is enabled by default.
     Set this to false to disable the behaviour.
     */
    public var isObservingForInterruptions: Bool {
        get { _isObservingForInterruptions }
        set {
            if newValue == _isObservingForInterruptions {
                return
            }
            
            if newValue {
                registerForInterruptionNotification()
            } else {
                unregisterForInterruptionNotification()
            }
        }
    }
    
    public weak var delegate: AudioSessionControllerDelegate?
    
    init(audioSession: AudioSession = AVAudioSession.sharedInstance()) {
        self.audioSession = audioSession
        registerForInterruptionNotification()
    }
    deinit {
        // Notification center holds weak references; observers are cleaned up automatically
        // when the observer deallocates. The Task-based cleanup from before races with deinit.
    }
    public func activateSession() throws {
        do {
            try audioSession.setActive(true, options: [])
            audioSessionIsActive = true
        } catch let error { throw error }
    }
    
    public func deactivateSession() throws {
        do {
            try audioSession.setActive(false, options: [])
            audioSessionIsActive = false
        } catch let error { throw error }
    }
    
    public func set(category: AVAudioSession.Category) throws {
        try audioSession.setCategory(category, mode: audioSession.mode, options: audioSession.categoryOptions)
    }
    
    // MARK: - Interruptions
    
    private func registerForInterruptionNotification() {
        notificationCenter.addObserver(self,
                                       selector: #selector(handleInterruption),
                                       name: AVAudioSession.interruptionNotification,
                                       object: nil)
        _isObservingForInterruptions = true
    }
    
    private nonisolated func unregisterForInterruptionNotification() {
        notificationCenter.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        Task { @MainActor in
            self._isObservingForInterruptions = false
        }
    }
    
    @objc nonisolated func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
        }

        switch type {
        case .began:
            let userInfoCopy = userInfo
            Task { @MainActor [weak self] in
                self?.handleInterruptionSync(type: .began)
            }
            _ = userInfoCopy
        case .ended:
            guard let typeValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                Task { @MainActor [weak self] in
                    self?.handleInterruptionSync(type: .ended(shouldResume: false))
                }
                return
            }

            let options = AVAudioSession.InterruptionOptions(rawValue: typeValue)
            let shouldResume = options.contains(.shouldResume)
            Task { @MainActor [weak self] in
                self?.handleInterruptionSync(type: .ended(shouldResume: shouldResume))
            }
        @unknown default:
            return
        }
    }

    private func handleInterruptionSync(type: InterruptionType) {
        delegate?.handleInterruption(type: type)
    }
    
}
