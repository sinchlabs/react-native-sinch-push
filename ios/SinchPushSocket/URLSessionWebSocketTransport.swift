//  URLSessionWebSocketTransport.swift — the only file that talks to a socket.
//
//  `URLSessionWebSocketTask` is Foundation, so this still compiles inside the
//  SwiftPM harness; it is kept separate from the client because it is the one
//  place where a real network can appear, and the client never imports it — it
//  receives a ``SocketTransportFactory`` (see SocketDependencies.swift) so a
//  test never loads this file's behaviour.
//
//  Two protocol requirements are visible here rather than in the client:
//
//    * SB-01 — a text message is not part of the protocol, so it is dropped
//      silently instead of being handed up as undecodable bytes.
//    * SB-56 — the background path closes with 1000, which is why ``close`` takes
//      a code rather than just a flag.

import Foundation

/// A `URLSessionWebSocketTask` behind the ``SocketTransport`` seam.
final class URLSessionWebSocketTransport: SocketTransport {
  var onOpen: (() -> Void)?
  var onBinary: ((Data) -> Void)?
  var onClose: ((SocketTransportClose) -> Void)?

  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var opened = false
  /// Guards against reporting a close twice: `URLSession` delivers an error and
  /// a close code, and the client only wants the first.
  private var closed = false
  /// Set when ``close(code:reason:)`` was called by us, so the resulting
  /// delegate callback is not re-reported as a peer close.
  private var closingLocally = false

  var isOpen: Bool { opened }

  func connect(to url: URL) {
    let configuration = URLSessionConfiguration.default
    // The socket is foreground-only (SB-56) and every poll is on a timer the
    // client owns, so nothing here should be waiting on a system resource.
    configuration.timeoutIntervalForRequest = 30
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration)
    self.session = session
    let task = session.webSocketTask(with: url)
    self.task = task
    task.resume()
    // `URLSessionWebSocketTask` has no "did open" callback; the handshake is
    // complete once `resume()` returns and the first send is accepted, which is
    // what `open()` reports. A rejected upgrade surfaces as `didCompleteWithError`
    // / `didCloseWith` and is handled by SB-50 (retryable from attempt 1).
    opened = true
    onOpen?()
    receiveNext()
  }

  func send(_ data: Data) {
    guard let task, opened else { return }
    task.send(.data(data)) { [weak self] error in
      guard let self, let error else { return }
      self.reportClose(code: 1006, reason: "send failed: \(error.localizedDescription)")
    }
  }

  func close(code: Int, reason: String?) {
    guard let task else { return }
    closingLocally = true
    let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
    task.cancel(with: closeCode, reason: reason?.data(using: .utf8))
    teardown(code: code, reason: reason)
  }

  private func receiveNext() {
    task?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let message):
        switch message {
        case .data(let data):
          // SB-01: one binary message is exactly one protocol frame.
          self.onBinary?(data)
        case .string:
          // Not part of the protocol. Ignored without error (SB-01).
          break
        @unknown default:
          break
        }
        self.receiveNext()
      case .failure(let error):
        self.reportClose(code: 1006, reason: error.localizedDescription)
      }
    }
  }

  private func reportClose(code: Int, reason: String?) {
    guard !closed else { return }
    closed = true
    teardown(code: code, reason: reason)
  }

  private func teardown(code: Int, reason: String?) {
    opened = false
    task = nil
    session?.invalidateAndCancel()
    session = nil
    // A locally requested close has already been reported to the caller, and
    // the client's generation guard (SB-51) would ignore it anyway; reporting
    // it twice is what used to turn one `stop()` into two reconnects.
    guard !closingLocally else {
      closingLocally = false
      return
    }
    onClose?(SocketTransportClose(code: code, reason: reason))
  }
}

/// Hands out ``URLSessionWebSocketTransport`` instances, one per attempt.
final class URLSessionWebSocketTransportFactory: SocketTransportFactory {
  func makeTransport() -> SocketTransport {
    URLSessionWebSocketTransport()
  }
}