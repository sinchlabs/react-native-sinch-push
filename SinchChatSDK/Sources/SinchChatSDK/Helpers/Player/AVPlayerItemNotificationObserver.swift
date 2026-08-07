//
//  AVPlayerItemNotificationObserver.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 12/03/2018.
//

import Foundation
import AVFoundation

@MainActor
protocol AVPlayerItemNotificationObserverDelegate: AnyObject {
    func itemDidPlayToEndTime()
}

/**
 Observes notifications posted by an AVPlayerItem.
 
 Currently only listening for the AVPlayerItemDidPlayToEndTime notification.
 */
@MainActor
class AVPlayerItemNotificationObserver {
    
    private let notificationCenter: NotificationCenter = NotificationCenter.default
    
    private(set) weak var observingItem: AVPlayerItem?
    weak var delegate: AVPlayerItemNotificationObserverDelegate?
    
    private(set) var isObserving: Bool = false
    
    deinit {
        let center = notificationCenter
        let item = observingItem
        if isObserving, let item = item {
            center.removeObserver(item)
        }
    }
    
    /**
     Will start observing notifications from an item.
     
     - parameter item: The item to observe.
     - important: Cannot observe more than one item at a time.
     */
    func startObserving(item: AVPlayerItem) {
        stopObservingCurrentItem()
        observingItem = item
        isObserving = true
        notificationCenter.addObserver(self, selector: #selector(itemDidPlayToEndTime), name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: item)
    }
    
    /**
     Stop receiving notifications for the current item.
     */
    func stopObservingCurrentItem() {
        guard let observingItem = observingItem, isObserving else {
            return
        }
        notificationCenter.removeObserver(self, name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: observingItem)
        self.observingItem = nil
        isObserving = false
    }
    
    @objc private func itemDidPlayToEndTime() {
        delegate?.itemDidPlayToEndTime()
    }
    
}
