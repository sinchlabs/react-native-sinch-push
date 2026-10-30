//  UIApplicationSocketLifecycle.swift — the foreground-only lifecycle (SB-56).
//
//  iOS is foreground-only and APNs stays the background channel: no background
//  modes are added, and nothing here tries to keep a socket alive past
//  `didEnterBackground`. The transitions RN-018 asks for are:
//
//      background  -> close with 1000, keep the config, cancel the backoff,
//                     flush nothing (the outbox persists on its own)
//      foreground  -> reconnect; the immediate Poll and the outbox flush then
//                     follow from that reconnect's HelloAck (SB-23)
//
//  `willEnterForegroundNotification` *and* `didBecomeActiveNotification` are both
//  observed. `willEnterForeground` fires first and is the right place to start
//  reconnecting; `didBecomeActive` fires on every active transition (including
//  from an interruption such as a phone call), and the client is idempotent
//  about a resume it is not suspended for, so subscribing to both costs
//  nothing and covers the case where the app becomes active without a matching
//  foreground transition.
//
//  Everything is behind `#if canImport(UIKit)`, so this file compiles to nothing
//  in the SwiftPM harness and the lifecycle rules are tested through
//  ``AppLifecycleObserving`` instead.

import Foundation

#if canImport(UIKit)
import UIKit

/// Drives ``SocketClient`` from `UIApplication` notifications.
final class UIApplicationSocketLifecycle: AppLifecycleObserving {
  var onBackground: (() -> Void)?
  var onForeground: (() -> Void)?

  private let client: SocketClient
  private var tokens: [NSObjectProtocol] = []
  private var isObserving = false

  init(client: SocketClient) {
    self.client = client
    // Bound here rather than by the caller so an observer cannot be installed
    // that watches the app lifecycle but never drives the client — which would
    // look like a working foreground-only socket and behave like none at all.
    self.onBackground = { [weak client] in client?.suspend() }
    self.onForeground = { [weak client] in client?.resume() }
  }

  deinit {
    stopObserving()
  }

  func startObserving() {
    guard !isObserving else { return }
    isObserving = true
    let center = NotificationCenter.default
    tokens.append(
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.onBackground?()
      })
    tokens.append(
      center.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.onForeground?()
      })
    tokens.append(
      center.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.onForeground?()
      })
  }

  func stopObserving() {
    guard isObserving else { return }
    isObserving = false
    let center = NotificationCenter.default
    for token in tokens {
      center.removeObserver(token)
    }
    tokens.removeAll()
  }
}
#endif