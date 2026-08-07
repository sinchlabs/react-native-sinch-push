//
//  AVPlayerItemObserver.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 28/07/2018.
//

import Foundation
import AVFoundation

@MainActor
protocol AVPlayerItemObserverDelegate: AnyObject {

    /**
     Called when the observed item updates the duration.
     */
    func item(didUpdateDuration duration: Double)

    /**
     Called when the observed item receives metadata
     */
    func item(didReceiveMetadata metadata: [AVTimedMetadataGroup])

}

/**
 Observing an AVPlayers status changes.
 */
@MainActor
final class AVPlayerItemObserver: NSObject, @unchecked Sendable {

    private nonisolated(unsafe) static var context = 0
    private let main: DispatchQueue = .main
    private let metadataOutput: AVPlayerItemMetadataOutput
    
    private struct AVPlayerItemKeyPath {
        static let duration = #keyPath(AVPlayerItem.duration)
        static let loadedTimeRanges = #keyPath(AVPlayerItem.loadedTimeRanges)
    }
    
    private(set) var isObserving: Bool = false
    
    private(set) weak var observingItem: AVPlayerItem?
    weak var delegate: AVPlayerItemObserverDelegate?
    
    override init() {
        metadataOutput = AVPlayerItemMetadataOutput()
        super.init()
        
        metadataOutput.setDelegate(self, queue: main)
    }
    
    deinit {
        let item = observingItem
        var context = AVPlayerItemObserver.context
        if let item = item, isObserving {
            item.removeObserver(self, forKeyPath: AVPlayerItemKeyPath.duration, context: &context)
            item.removeObserver(self, forKeyPath: AVPlayerItemKeyPath.loadedTimeRanges, context: &context)
            item.remove(metadataOutput)
        }
    }
    
    /**
     Start observing an item. Will remove self as observer from old item, if any.
     
     - parameter item: The player item to observe.
     */
    func startObserving(item: AVPlayerItem) {
        stopObservingCurrentItem()
        isObserving = true
        observingItem = item
        item.addObserver(self, forKeyPath: AVPlayerItemKeyPath.duration, options: [.new], context: &AVPlayerItemObserver.context)
        item.addObserver(self, forKeyPath: AVPlayerItemKeyPath.loadedTimeRanges, options: [.new], context: &AVPlayerItemObserver.context)
        item.add(metadataOutput)
    }
    
    func stopObservingCurrentItem() {
        guard let observingItem = observingItem, isObserving else {
            return
        }
        observingItem.removeObserver(self, forKeyPath: AVPlayerItemKeyPath.duration, context: &AVPlayerItemObserver.context)
        observingItem.removeObserver(self, forKeyPath: AVPlayerItemKeyPath.loadedTimeRanges, context: &AVPlayerItemObserver.context)
        observingItem.remove(metadataOutput)
        isObserving = false
        self.observingItem = nil
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard context == &AVPlayerItemObserver.context, let observedKeyPath = keyPath else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        
        switch observedKeyPath {
        case AVPlayerItemKeyPath.duration:
            if let duration = change?[.newKey] as? CMTime {
                let seconds = duration.seconds
                Task { @MainActor [weak self] in
                    self?.delegate?.item(didUpdateDuration: seconds)
                }
            }

        case AVPlayerItemKeyPath.loadedTimeRanges:
            if let ranges = change?[.newKey] as? [NSValue], let duration = ranges.first?.timeRangeValue.duration {
                let seconds = duration.seconds
                Task { @MainActor [weak self] in
                    self?.delegate?.item(didUpdateDuration: seconds)
                }
            }

        default: break
            
        }
    }
}

extension AVPlayerItemObserver: AVPlayerItemMetadataOutputPushDelegate {
    nonisolated func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        nonisolated(unsafe) let captured = groups
        Task { @MainActor [weak self] in
            self?.delegate?.item(didReceiveMetadata: captured)
        }
    }
}
