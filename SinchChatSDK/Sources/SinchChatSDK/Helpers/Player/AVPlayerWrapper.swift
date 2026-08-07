//
//  AVPlayerWrapper.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 06/03/2018.
//  Copyright © 2018 Jørgen Henrichsen. All rights reserved.
//

import Foundation
import AVFoundation
import MediaPlayer

public enum PlaybackEndedReason: String {
    case playedUntilEnd
    case playerStopped
    case skippedToNext
    case skippedToPrevious
    case jumpedToIndex
}

public enum TimeEventFrequency {
    case everySecond
    case everyHalfSecond
    case everyQuarterSecond
    case custom(time: CMTime)
    
    func getTime() -> CMTime {
        switch self {
        case .everySecond: return CMTime(value: 1, timescale: 1)
        case .everyHalfSecond: return CMTime(value: 1, timescale: 2)
        case .everyQuarterSecond: return CMTime(value: 1, timescale: 4)
        case .custom(let time): return time
        }
    }
}
@MainActor
class AVPlayerWrapper: AVPlayerWrapperProtocol {
    
    struct Constants {
        static let assetPlayableKey = "playable"
    }
    
    // MARK: - Properties
    
    fileprivate var avPlayer = AVPlayer()
    private let playerObserver = AVPlayerObserver()
    internal let playerTimeObserver: AVPlayerTimeObserver
    private let playerItemNotificationObserver = AVPlayerItemNotificationObserver()
    private let playerItemObserver = AVPlayerItemObserver()

    fileprivate var initialTime: TimeInterval?
    fileprivate var pendingAsset: AVAsset?

    /// True when the track was paused for the purpose of switching tracks
    fileprivate var pausedForLoad: Bool = false
    
    public init() {
        playerTimeObserver = AVPlayerTimeObserver(periodicObserverTimeInterval: timeEventFrequency.getTime())
        playerTimeObserver.player = avPlayer

        playerObserver.player = avPlayer
        playerObserver.delegate = self
        playerTimeObserver.delegate = self
        playerItemNotificationObserver.delegate = self
        playerItemObserver.delegate = self

        // disabled since we're not making use of video playback
        avPlayer.allowsExternalPlayback = false
        
        playerTimeObserver.registerForPeriodicTimeEvents()
    }
    
    deinit {
        // AVPlayerTimeObserver is @MainActor, but deinit cannot be isolated.
        // Setting a property on @MainActor-isolated class from a non-isolated deinit
        // is unsafe, so we just nil out what we can synchronously.
    }
    // MARK: - AVPlayerWrapperProtocol

    fileprivate(set) var state: AVPlayerWrapperState = AVPlayerWrapperState.idle {
        didSet {
            if oldValue != state {
                delegate?.AVWrapper(didChangeState: state)
            }
        }
    }

    /**
     True if the last call to load(from:playWhenReady) had playWhenReady=true.
     */
    fileprivate(set) var playWhenReady: Bool = true
    
    var currentItem: AVPlayerItem? {
        avPlayer.currentItem
    }
    
    var currentTime: TimeInterval {
        let seconds = avPlayer.currentTime().seconds
        return seconds.isNaN ? 0 : seconds
    }
    
    var duration: TimeInterval {
        if let seconds = currentItem?.asset.duration.seconds, !seconds.isNaN {
            return seconds
        } else if let seconds = currentItem?.duration.seconds, !seconds.isNaN {
            return seconds
        } else if let seconds = currentItem?.seekableTimeRanges.last?.timeRangeValue.duration.seconds,
                !seconds.isNaN {
            return seconds
        }
        return 0.0
    }
    
    var bufferedPosition: TimeInterval {
        currentItem?.loadedTimeRanges.last?.timeRangeValue.end.seconds ?? 0
    }

    var reasonForWaitingToPlay: AVPlayer.WaitingReason? {
        avPlayer.reasonForWaitingToPlay
    }

    var rate: Float {
        get { avPlayer.rate }
        set { avPlayer.rate = newValue }
    }

    weak var delegate: AVPlayerWrapperDelegate?
    
    var bufferDuration: TimeInterval = 0

    var timeEventFrequency: TimeEventFrequency = .everySecond {
        didSet {
            playerTimeObserver.periodicObserverTimeInterval = timeEventFrequency.getTime()
        }
    }
    
    var volume: Float {
        get { avPlayer.volume }
        set { avPlayer.volume = newValue }
    }
    
    var isMuted: Bool {
        get { avPlayer.isMuted }
        set { avPlayer.isMuted = newValue }
    }

    var automaticallyWaitsToMinimizeStalling: Bool {
        get { avPlayer.automaticallyWaitsToMinimizeStalling }
        set { avPlayer.automaticallyWaitsToMinimizeStalling = newValue }
    }
    
    func play() {
        playWhenReady = true
        avPlayer.play()
    }
    
    func pause() {
        playWhenReady = false
        avPlayer.pause()
    }
    
    func togglePlaying() {
        switch avPlayer.timeControlStatus {
        case .playing, .waitingToPlayAtSpecifiedRate:
            pause()
        case .paused:
            play()
        @unknown default:
            fatalError("Unknown AVPlayer.timeControlStatus")
        }
    }
    
    func stop() {
        pause()
        reset(soft: false)
    }
    
    func seek(to seconds: TimeInterval) {
       // if the player is loading then we need to defer seeking until it's ready.
       if state == AVPlayerWrapperState.loading {
         initialTime = seconds
       } else {
         avPlayer.seek(to: CMTimeMakeWithSeconds(seconds, preferredTimescale: 1000)) { [weak self] finished in
             guard let self = self else { return }
             if self.initialTime != nil {
                 self.initialTime = nil
                 if self.playWhenReady {
                     self.play()
                 }
             }
             let delegate = self.delegate
             let secondsInt = Int(seconds)
             Task { @MainActor in
                 delegate?.AVWrapper(seekTo: secondsInt, didFinish: finished)
             }
         }
       }
    }
    
    func load(from url: URL, playWhenReady: Bool, options: [String: Any]? = nil) {
        reset(soft: true)
        self.playWhenReady = playWhenReady

        if currentItem?.status == .failed {
            recreateAVPlayer()
        }

        pendingAsset = AVURLAsset(url: url, options: options)
        
        if let pendingAsset = pendingAsset {
            state = .loading
            pendingAsset.loadValuesAsynchronously(forKeys: [Constants.assetPlayableKey], completionHandler: { [weak self] in
                guard let self = self else { return }

                var error: NSError?
                let status = pendingAsset.statusOfValue(forKey: Constants.assetPlayableKey, error: &error)

                // Capture data needed for the metadata processing in the MainActor task.
                let chapterLocales = pendingAsset.availableChapterLocales
                let hasChapterLocales = !chapterLocales.isEmpty
                var chapterGroups: [AVTimedMetadataGroup] = []
                if hasChapterLocales {
                    for locale in chapterLocales {
                        chapterGroups.append(contentsOf: pendingAsset.chapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: nil))
                    }
                }
                var timedMetadataGroups: [AVTimedMetadataGroup] = []
                if !hasChapterLocales {
                    for format in pendingAsset.availableMetadataFormats {
                        let timeRange = CMTimeRange(start: CMTime(seconds: 0, preferredTimescale: 1000), end: pendingAsset.duration)
                        timedMetadataGroups.append(AVTimedMetadataGroup(items: pendingAsset.metadata(forFormat: format), timeRange: timeRange))
                    }
                }
                let pendingMatch: Bool = {
                    if let current = self.pendingAsset, current.isEqual(pendingAsset) {
                        return true
                    }
                    return false
                }()
                let shouldInstall: Bool = (status == .loaded && pendingMatch)

                nonisolated(unsafe) let unsafeChapterGroups = chapterGroups
                nonisolated(unsafe) let unsafeTimedMetadataGroups = timedMetadataGroups
                nonisolated(unsafe) let unsafeHasChapterLocales = hasChapterLocales

                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    switch status {
                    case .loaded:
                        if shouldInstall, let asset = self.pendingAsset {
                            let currentItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: [Constants.assetPlayableKey])
                            currentItem.preferredForwardBufferDuration = self.bufferDuration
                            self.avPlayer.replaceCurrentItem(with: currentItem)

                            // Register for events
                            self.playerTimeObserver.registerForBoundaryTimeEvents()
                            self.playerObserver.startObserving()
                            self.playerItemNotificationObserver.startObserving(item: currentItem)
                            self.playerItemObserver.startObserving(item: currentItem)

                            if unsafeHasChapterLocales {
                                self.delegate?.AVWrapper(didReceiveMetadata: unsafeChapterGroups)
                            } else {
                                self.delegate?.AVWrapper(didReceiveMetadata: unsafeTimedMetadataGroups)
                            }
                        }

                    case .failed:
                        if shouldInstall {
                            self.delegate?.AVWrapper(failedWithError: error)
                            self.pendingAsset = nil
                        }

                    case .cancelled:
                        break

                    default:
                        break
                    }
                }
            })
        }
    }
    
    func load(from url: URL, playWhenReady: Bool, initialTime: TimeInterval? = nil, options: [String : Any]? = nil) {
        self.initialTime = initialTime

        pausedForLoad = true
        pause()

        self.load(from: url, playWhenReady: playWhenReady, options: options)
    }
    
    // MARK: - Util
    
    private func reset(soft: Bool) {
        playerItemObserver.stopObservingCurrentItem()
        playerTimeObserver.unregisterForBoundaryTimeEvents()
        playerItemNotificationObserver.stopObservingCurrentItem()

        pendingAsset?.cancelLoading()
        pendingAsset = nil
        
        if !soft {
            avPlayer.replaceCurrentItem(with: nil)
        }
    }
    
    /// Will recreate the AVPlayer instance. Used when the current one fails.
    private func recreateAVPlayer() {
        let player = AVPlayer()
        playerObserver.player = player
        playerTimeObserver.player = player
        playerTimeObserver.registerForPeriodicTimeEvents()
        avPlayer = player
        delegate?.AVWrapperDidRecreateAVPlayer()
    }
    
}

extension AVPlayerWrapper: AVPlayerObserverDelegate {
    
    // MARK: - AVPlayerObserverDelegate
    
    func player(didChangeTimeControlStatus status: AVPlayer.TimeControlStatus) {
        switch status {
        case .paused:
            if currentItem == nil {
                state = .idle
            } else if pausedForLoad != true {
                state = .paused
            }
        case .waitingToPlayAtSpecifiedRate:
            state = .buffering
        case .playing:
            state = .playing
        @unknown default:
            break
        }
    }
    
    func player(statusDidChange status: AVPlayer.Status) {
        switch status {
        case .readyToPlay:
            state = .ready
            pausedForLoad = false
            if playWhenReady && (initialTime ?? 0) == 0 {
                play()
            } else if let initialTime = initialTime {
                seek(to: initialTime)
            }
            
        case .failed:
            delegate?.AVWrapper(failedWithError: avPlayer.error)
            
        case .unknown:
            break
        @unknown default:
            break
        }
    }
}

extension AVPlayerWrapper: AVPlayerTimeObserverDelegate {
    
    // MARK: - AVPlayerTimeObserverDelegate
    
    func audioDidStart() {
        state = .playing
    }
    
    func timeEvent(time: CMTime) {
        delegate?.AVWrapper(secondsElapsed: time.seconds)
    }
    
}

extension AVPlayerWrapper: AVPlayerItemNotificationObserverDelegate {
    
    // MARK: - AVPlayerItemNotificationObserverDelegate
    
    func itemDidPlayToEndTime() {
        delegate?.AVWrapperItemDidPlayToEndTime()
    }
    
}

extension AVPlayerWrapper: AVPlayerItemObserverDelegate {
    
    // MARK: - AVPlayerItemObserverDelegate
    
    func item(didUpdateDuration duration: Double) {
        delegate?.AVWrapper(didUpdateDuration: duration)
    }
    
    func item(didReceiveMetadata metadata: [AVTimedMetadataGroup]) {
        delegate?.AVWrapper(didReceiveMetadata: metadata)
    }
    
}
