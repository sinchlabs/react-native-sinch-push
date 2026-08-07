//
//  AudioPlayerObserver.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 09/03/2018.
//  Copyright © 2018 Jørgen Henrichsen. All rights reserved.
//

import Foundation
import AVFoundation

@MainActor
protocol AVPlayerObserverDelegate: AnyObject {

    /**
     Called when the AVPlayer.status changes.
     */
    func player(statusDidChange status: AVPlayer.Status)

    /**
     Called when the AVPlayer.timeControlStatus changes.
     */
    func player(didChangeTimeControlStatus status: AVPlayer.TimeControlStatus)
}

/**
 Observing an AVPlayers status changes.
 */
@MainActor
final class AVPlayerObserver: NSObject, @unchecked Sendable {

    private nonisolated(unsafe) static var context = 0
    private let main: DispatchQueue = .main

    private struct AVPlayerKeyPath {
        static let status = #keyPath(AVPlayer.status)
        static let timeControlStatus = #keyPath(AVPlayer.timeControlStatus)
    }

    private let statusChangeOptions: NSKeyValueObservingOptions = [.new, .initial]
    private let timeControlStatusChangeOptions: NSKeyValueObservingOptions = [.new]
    private(set) var isObserving: Bool = false

    weak var delegate: AVPlayerObserverDelegate?
    weak var player: AVPlayer? {
        willSet {
            stopObserving()
        }
    }

    deinit {
        let player = self.player
        var context = AVPlayerObserver.context
        if let player = player, isObserving {
            player.removeObserver(self, forKeyPath: AVPlayerKeyPath.status, context: &context)
            player.removeObserver(self, forKeyPath: AVPlayerKeyPath.timeControlStatus, context: &context)
        }
    }

    /**
     Start receiving events from this observer.
     */
    func startObserving() {
        guard let player = player else {
            return
        }
        stopObserving()
        isObserving = true
        player.addObserver(self, forKeyPath: AVPlayerKeyPath.status, options: statusChangeOptions, context: &AVPlayerObserver.context)
        player.addObserver(self, forKeyPath: AVPlayerKeyPath.timeControlStatus, options: timeControlStatusChangeOptions, context: &AVPlayerObserver.context)
    }

    func stopObserving() {
        guard let player = player, isObserving else {
            return
        }
        player.removeObserver(self, forKeyPath: AVPlayerKeyPath.status, context: &AVPlayerObserver.context)
        player.removeObserver(self, forKeyPath: AVPlayerKeyPath.timeControlStatus, context: &AVPlayerObserver.context)
        isObserving = false
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard context == &AVPlayerObserver.context, let observedKeyPath = keyPath else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        switch observedKeyPath {
        case AVPlayerKeyPath.status:
            if let statusNumber = change?[.newKey] as? NSNumber {
                let status = AVPlayer.Status(rawValue: statusNumber.intValue) ?? .unknown
                Task { @MainActor [weak self] in
                    self?.delegate?.player(statusDidChange: status)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.delegate?.player(statusDidChange: .unknown)
                }
            }

        case AVPlayerKeyPath.timeControlStatus:
            if let statusNumber = change?[.newKey] as? NSNumber {
                let status = AVPlayer.TimeControlStatus(rawValue: statusNumber.intValue) ?? .paused
                Task { @MainActor [weak self] in
                    self?.delegate?.player(didChangeTimeControlStatus: status)
                }
            }

        default:
            break
        }
    }

    private func handleStatusChange(_ change: [NSKeyValueChangeKey: Any]?) {
        // Inlined above to avoid sending `change` across actor boundaries.
        _ = change
    }

    private func handleTimeControlStatusChange(_ change: [NSKeyValueChangeKey: Any]?) {
        // Inlined above to avoid sending `change` across actor boundaries.
        _ = change
    }
}
