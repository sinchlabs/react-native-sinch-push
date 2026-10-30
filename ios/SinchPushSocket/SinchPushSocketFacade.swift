//  SinchPushSocketFacade.swift — the @objc surface `SinchPush.mm` talks to.
//
//  This is the whole React-facing seam, and it is deliberately the *only* place
//  that knows about the host app: the client below it takes configuration and
//  dependencies, and everything platform-shaped (UIApplication, UserNotifications,
//  Keychain, URLSession) is supplied from `iOS/` or `SystemDependencies.swift`.
//  SinchPush.mm therefore translates a promise block and an NSDictionary and
//  knows nothing about frames, timers or reports — which is what keeps the
//  behaviour testable under `swift test` and keeps the ObjC++ glue thin enough
//  to read.
//
//  Every method here maps 1:1 onto a method in `src/NativeSinchPush.ts`, which
//  is the JS↔native contract; the shapes returned are the ones
//  `src/pushSocket/types.ts` declares (`PushSocketState`, `PushSocketMessage`).

import Foundation

/// Events the facade emits. The names are the strings `SinchPush.mm` passes to
/// `sendEventWithName:` and the strings the JS facade listens on.
@objc public enum SinchPushSocketEvent: Int {
  case socketMessage = 1
  case socketState = 2
}

/// Implemented by `SinchPush.mm`. Kept as a protocol rather than a block
/// property so the emitter is one object and the event names live here next to
/// the code that raises them.
@objc public protocol SinchPushSocketFacadeDelegate: AnyObject {
  func socketFacadeDidEmitMessage(_ message: [String: Any])
  func socketFacadeDidEmitState(_ state: [String: Any])
  /// SB-48: the relay refused the credential. The host refreshes it and
  /// calls back with ``SinchPushSocketFacade/updateToken(_:)``.
  func socketFacadeRequiresTokenRefresh()
}

/// Creates the lifecycle observer that drives a client.
///
/// Injected because the live observer needs `UIApplication` (`iOS/`, which the
/// SwiftPM harness on macOS cannot compile), and "is the observer still
/// attached?" is a fact SB-66 needs asserted after a stop and a restart. The
/// fake a test builds observes the same transitions the live one does, so what
/// is asserted is the wiring rather than a stand-in for it.
typealias SocketLifecycleObserverFactory = (SocketClient) -> AppLifecycleObserving

/// Owns one ``SocketClient`` and its dependencies.
@objc(SinchPushSocket)
public final class SinchPushSocketFacade: NSObject {

  /// The ObjC name is spelled out rather than left to Swift's export, because
  /// the bridge calls it and a name that depends on export inference is a build
  /// that breaks when the inference changes.
  @objc(sharedInstance) public static let shared = SinchPushSocketFacade()

  /// Weak, because the delegate is the RCTEventEmitter, which owns the bridge and
  /// can be torn down independently of this object.
  @objc public weak var delegate: SinchPushSocketFacadeDelegate?

  /// Raised when a provider-push report is queued; `SinchPush.mm` forwards it as `SinchPush:onReportQueued`.
  @objc public static let reportQueuedNotificationName = "SinchPushReportQueuedNotification"

  /// The client, created on first use. Exposed for a host that wants to swap a
  /// dependency; nothing outside the module needs it.
  private(set) var client: SocketClient?

  private let store: SocketStateStore
  private let tokenStore: AuthTokenStore
  private let installationIdStore: InstallationIdStore
  private let relaySwitch: RelaySwitchStore
  private let presenter: NotificationPresenting
  private let deliveredNotifications: DeliveredNotificationLookup
  /// The one dedupe set of the process: the client and the push path
  /// in `SinchPush.mm` both go through it.
  private let seenRegistry: SeenMessageRegistry
  /// The provider-push report outbox.
  private let reportOutbox: ReportOutbox
  private let pushDecider: PushPresentationDecider
  private let logger: SocketLogger
  /// The socket seam. Held as a property rather than a literal in
  /// ``makeClient()`` because "relay off ⇒ no socket" (SB-66) is only a testable
  /// claim if opening a socket is something a test can count.
  private let transportFactory: SocketTransportFactory
  /// One serial queue by default; a manual clock in the harness, so "no socket
  /// was opened" is a settled fact when the call returns rather than a race.
  private let scheduler: Scheduler
  /// `nil` builds the `UIApplication` observer where UIKit exists and no
  /// observer anywhere else.
  private let lifecycleFactory: SocketLifecycleObserverFactory?
  private var lifecycle: AppLifecycleObserving?
  private var hasConfiguredLifecycle = false

  /// The config most recently handed to ``start(config:)``, kept so a token
  /// refresh can rebuild it (SB-48) without JS resending everything.
  private var currentConfiguration: SocketConfiguration?
  // MARK: - Init

  /// The initialiser is internal on purpose: every dependency type is internal
  /// to the pod, and the only thing that has to be reachable from outside is
  /// ``shared`` plus the `@objc` methods below, whose signatures are all
  /// Foundation types the ObjC++ bridge already has.
  init(
    store: SocketStateStore = UserDefaultsSocketStateStore(),
    tokenStore: AuthTokenStore = SocketAuthTokenStore(),
    installationIdStore: InstallationIdStore = KeychainInstallationIdStore.shared,
    relaySwitch: RelaySwitchStore = UserDefaultsRelaySwitchStore(),
    presenter: NotificationPresenting = makeDefaultSocketPresenter(),
    deliveredNotifications: DeliveredNotificationLookup = makeDefaultDeliveredNotificationLookup(),
    seenRegistry: SeenMessageRegistry? = nil,
    reportOutbox: ReportOutbox? = nil,
    logger: SocketLogger = PrintSocketLogger(),
    transportFactory: SocketTransportFactory = URLSessionWebSocketTransportFactory(),
    scheduler: Scheduler = DispatchScheduler(),
    lifecycleFactory: SocketLifecycleObserverFactory? = nil
  ) {
    self.store = store
    self.tokenStore = tokenStore
    self.installationIdStore = installationIdStore
    self.relaySwitch = relaySwitch
    self.presenter = presenter
    self.deliveredNotifications = deliveredNotifications
    self.transportFactory = transportFactory
    self.scheduler = scheduler
    self.lifecycleFactory = lifecycleFactory
    let registry = seenRegistry ?? SeenMessageRegistry(store: store)
    self.seenRegistry = registry
    let clock: () -> Int64 = { [scheduler] in scheduler.nowMs() }
    let outbox = reportOutbox ?? ReportOutbox(store: store, now: clock)
    self.reportOutbox = outbox
    self.pushDecider = PushPresentationDecider(
      registry: registry,
      outbox: outbox,
      onQueued: {
        NotificationCenter.default.post(
          name: Notification.Name(SinchPushSocketFacade.reportQueuedNotificationName),
          object: nil)
      })
    self.logger = logger
    super.init()
    #if os(iOS)
    // Wire the dismiss action (RN-019) after `super.init()` rather than inside
    // the default argument: the default presenter is created *by* this facade,
    // so referring back to `shared` from there would recurse.
    if let presenter = presenter as? SocketNotificationPresenter {
      presenter.onDismissed = { [weak self] messageId in
        self?.notificationDidDismiss(messageId: messageId)
      }
    }
    #endif
  }

  private func makeClient() -> SocketClient {
    let client = SocketClient(
      transportFactory: transportFactory,
      // One serial queue for transport callbacks and timers. Two contexts would
      // let a reconnect scheduled from inside a frame handler race the handler
      // that scheduled it.
      scheduler: scheduler,
      random: SystemRandomSource(),
      store: store,
      tokenStore: tokenStore,
      presenter: presenter,
      logger: logger,
      // SB-59: read per Hello, from the same store `getInstallationId()` uses,
      // so the relay and the push API see one id.
      deviceInfo: SystemDeviceInfoProvider(
        installationId: { [installationIdStore] in try installationIdStore.installationId() },
        logger: logger,
        relaySwitch: relaySwitch),
      deliveredNotifications: deliveredNotifications,
      seenRegistry: seenRegistry)
    client.setCallbacks(
      SocketClient.Callbacks(
        onState: { [weak self] state in
          self?.delegate?.socketFacadeDidEmitState(state.dictionary)
        },
        onMessage: { [weak self] message in
          self?.delegate?.socketFacadeDidEmitMessage(message.dictionary)
        },
        onLog: { [weak self] line in
          self?.logger.log(line)
        },
        onAuthRequired: { [weak self] in
          self?.delegate?.socketFacadeRequiresTokenRefresh()
        }))
    return client
  }

  // MARK: - Lifecycle

  /// `startPushSocket(config:)` in the TurboModule spec.
  ///
  /// The config map is `PushSocketConfig` from `src/pushSocket/types.ts`:
  /// `url`, `authToken`, `projectId`, `appId`, `userId`, optional
  /// `pollIntervalMs`, `sdkVersion` and `displayNotifications`.
  ///
  /// Throws ``SocketStartError/relayDisabled`` (SB-66) while the relay is
  /// off, before anything is stored or opened; `SinchPush.mm` rejects the promise
  /// with `E_RELAY_DISABLED`. Seen from ObjC this is `startWithConfig:error:`.
  @objc public func start(config: NSDictionary) throws {
    guard relaySwitch.isEnabled else { throw SocketStartError.relayDisabled }
    guard let configuration = SocketConfiguration(configMap: config) else {
      logger.log("start(config:) called without a usable config map; ignoring")
      return
    }
    currentConfiguration = configuration
    let client = existingOrNewClient()
    client.updateConfiguration(configuration)
    startLifecycleObservingIfNeeded()
  }

  /// `stopPushSocket()`.
  @objc public func stop() {
    stopLifecycleObserving()
    client?.stop()
  }

  /// The relay off switch (SB-66). Persists first, so a process that dies
  /// mid-switch comes back in the state the host asked for. Off stops the socket
  /// (the same stop as ``stop()``: the client and the lifecycle observer); on
  /// starts nothing - the host calls `start`, as after any other stop.
  @objc public func setRelayEnabled(_ enabled: Bool) {
    relaySwitch.setEnabled(enabled)
    if !enabled { stop() }
  }

  /// Whether the relay is on: the persisted value, `false` when never switched on.
  @objc public func isRelayEnabled() -> Bool {
    relaySwitch.isEnabled
  }

  /// `NSError.code` of the error ``start(config:)`` throws while the relay is off.
  @objc public static var relayDisabledErrorCode: Int { SocketStartError.relayDisabledCode }

  /// `NSError.domain` of that same error.
  @objc public static var relayDisabledErrorDomain: String { SocketStartError.errorDomain }

  /// RN-008's credential rotation: a new JWT, a fresh `Hello`, no restart of the
  /// host app. Also the way back from `auth_required`.
  ///
  /// Ignore token/lifecycle reconnects while relay is disabled.
  @objc public func updateToken(_ token: String) {
    guard relaySwitch.isEnabled else {
      logger.log("updateToken: the relay is off; keeping the socket closed")
      return
    }
    guard var configuration = currentConfiguration else { return }
    configuration.authToken = token
    currentConfiguration = configuration
    client?.updateConfiguration(configuration)
  }

  /// `getInstallationId()` — the per-install id.
  ///
  /// The value identifies an *install*, so it exists with or without a socket.
  ///
  /// `nil` means there is no id to give; `SinchPush.mm` turns that into
  /// `E_INSTALLATION_ID_UNAVAILABLE`.
  @objc public func installationId() -> String? {
    do {
      return try installationIdStore.installationId()
    } catch {
      logger.log("getInstallationId: \(error)")
      return nil
    }
  }

  /// `getDeviceInfo()` — the facts `Subscribe` carries (SB-61).
  ///
  /// The same provider and the same installation-id store as `Hello`, so the
  /// push API and the relay are told the same thing. Needs no client. The
  /// `sdkVersion` is always the built-in one: the config's override is a
  /// dev/test knob for `Hello` only.
  ///
  /// `nil` when the installation id is unavailable, which `SinchPush.mm` turns
  /// into `E_INSTALLATION_ID_UNAVAILABLE` like ``installationId()``.
  @objc public func deviceInfo() -> NSDictionary? {
    guard let id = installationId() else { return nil }
    let info = SystemDeviceInfoProvider(
      installationId: { id }, logger: logger, relaySwitch: relaySwitch
    )
      .current(sdkVersionOverride: nil)
    return info.dictionary as NSDictionary
  }

  /// `getPushSocketState()`. Never fabricates a status: an unstarted client
  /// reports `idle`, which is what it is.
  @objc public func stateDictionary() -> NSDictionary {
    let state = client?.currentState ?? SocketState(status: .idle)
    return state.dictionary as NSDictionary
  }

  /// `getPendingPushMessages()`.
  @objc public func pendingMessages() -> NSArray {
    let messages = client?.currentPendingMessages ?? []
    return messages.map { $0.dictionary } as NSArray
  }

  /// `clearPendingPushMessages()`.
  @objc public func clearPendingMessages() {
    client?.clearPendingMessages()
  }

  /// `reportPushMessageStatus(messageId, status)` — RN-004's public API.
  ///
  /// Queued rather than sent when the socket is not connected, which is the
  /// iOS case that matters: a notification can be dismissed while the app is in
  /// the background and the report still has to reach the relay (SB-35).
  @objc public func report(messageId: String, status: String) {
    guard let parsed = SocketDeliveryStatus.hostReportable(status) else {
      logger.log("report(\(status)) is not a host-reportable status; ignoring")
      return
    }
    ensureClient()
    client?.report(messageId: messageId, status: parsed)
  }

  /// RN-031: the host app tells native whether an in-app handler is registered,
  /// which is what the `whenUnhandled` display rule keys on. Same call Android
  /// uses (`setHandlerRegistered`).
  @objc public func setHandlerRegistered(_ registered: Bool) {
    ensureClient()
    client?.setHandlerRegistered(registered)
  }

  /// RN-019: a socket notification was dismissed by the user (the
  /// `UNNotificationDismissActionIdentifier` branch of the notification
  /// category). The report is queued, so it survives a suspended socket.
  @objc public func notificationDidDismiss(messageId: String) {
    ensureClient()
    client?.report(messageId: messageId, status: .dismissed)
  }

  // MARK: - Cross-channel dedupe

  /// `willPresentNotification:` — whether this notification should be handled as
  /// today (emit the JS event, present it) or is a copy of a message another
  /// channel delivered first (no event, present nothing). Marks an unseen id.
  /// Socket-originated local notifications always answer `true`.
  @objc public func shouldPresentPush(userInfo: NSDictionary, requestIdentifier: String)
    -> Bool
  {
    pushDecider.decide(
      userInfo: userInfo as? [AnyHashable: Any] ?? [:],
      requestIdentifier: requestIdentifier) == .present
  }

  /// `+didReceiveRemoteNotification:` — marks the push's id (see
  /// ``PushPresentationDecider/decideRemoteNotification(userInfo:appIsActive:)``)
  /// and answers `true` unless it is a copy. An active app's alert push is
  /// looked up but not marked (`willPresent` marks it).
  @objc public func shouldHandleRemotePush(userInfo: NSDictionary, appIsActive: Bool) -> Bool {
    pushDecider.decideRemoteNotification(
      userInfo: userInfo as? [AnyHashable: Any] ?? [:], appIsActive: appIsActive) == .present
  }

  // MARK: - Provider-push report outbox

  /// `getReportOutbox()` — the queued provider-push reports, oldest first.
  @objc public func reportOutboxEntries() -> [NSDictionary] {
    reportOutbox.snapshot().map { entry in
      [
        "messageId": entry.messageId,
        "subscriberId": entry.subscriberId,
        "enqueuedAt": NSNumber(value: entry.enqueuedAtMs),
      ] as NSDictionary
    }
  }

  /// `removeReportOutboxEntries(entries)` — drops the reports JS flushed; entries without both keys are ignored.
  @objc public func removeReportOutboxEntries(_ entries: [NSDictionary]) {
    let keys = entries.compactMap { entry -> (messageId: String, subscriberId: String)? in
      guard let messageId = entry["messageId"] as? String, !messageId.isEmpty,
        let subscriberId = entry["subscriberId"] as? String, !subscriberId.isEmpty
      else { return nil }
      return (messageId, subscriberId)
    }
    reportOutbox.remove(keys: keys)
  }

  /// `clearReportOutbox()` — drops every queued report.
  @objc public func clearReportOutbox() {
    reportOutbox.clear()
  }

  /// The lifecycle observer is UIApplication-driven on iOS; this seam exists so
  /// a host (or a test) can drive the transitions without a running app.
  ///
  /// Ignore token/lifecycle reconnects while relay is disabled.
  @objc public func applyLifecycleSignal(_ signal: String) {
    guard relaySwitch.isEnabled else {
      logger.log("lifecycle signal '\(signal)' ignored: the relay is off")
      return
    }
    switch signal {
    case "background": client?.suspend()
    case "foreground": client?.resume()
    default: logger.log("unknown lifecycle signal '\(signal)'")
    }
  }

  // MARK: - Internals

  @discardableResult
  private func ensureClient() -> SocketClient {
    existingOrNewClient()
  }

  private func existingOrNewClient() -> SocketClient {
    if let client { return client }
    let client = makeClient()
    self.client = client
    // A facade created after a previous process persisted a config (RN-008's
    // relaunch case) picks it up from the store + Keychain on `start()`.
    return client
  }

  private func startLifecycleObservingIfNeeded() {
    guard !hasConfiguredLifecycle else { return }
    hasConfiguredLifecycle = true
    guard let client else { return }
    if let lifecycleFactory {
      let observer = lifecycleFactory(client)
      observer.startObserving()
      lifecycle = observer
      return
    }
    #if canImport(UIKit)
    let observer = UIApplicationSocketLifecycle(client: client)
    observer.startObserving()
    lifecycle = observer
    #endif
  }

  /// Reset hasConfiguredLifecycle when detaching so the next start reattaches.
  private func stopLifecycleObserving() {
    lifecycle?.stopObserving()
    lifecycle = nil
    hasConfiguredLifecycle = false
  }
}

// MARK: - Config decoding

/// The presenter to use when the host supplies none.
///
/// On iOS that is the real thing: `UNNotificationCategoryOptionCustomDismissAction`
/// is the only route to a DISMISSED report for a notification the user swiped
/// away (RN-019), so a build that silently fell back to the no-op presenter
/// would deliver messages with no notification *and* no dismissal reporting.
func makeDefaultSocketPresenter() -> NotificationPresenting {
  #if os(iOS)
  return SocketNotificationPresenter()
  #else
  return NoopNotificationPresenter()
  #endif
}

/// The delivered-notification lookup to use when the host supplies none: the
/// real notification centre on iOS (RN-045).
func makeDefaultDeliveredNotificationLookup() -> DeliveredNotificationLookup {
  #if os(iOS)
  return SystemDeliveredNotificationLookup()
  #else
  return NoDeliveredNotifications()
  #endif
}

extension SocketConfiguration {
  /// Decode the `PushSocketConfig` map JS sends.
  ///
  /// Returns `nil` rather than throwing: the promise in `SinchPush.mm` is
  /// rejected by the JS facade before it ever gets here (`startPushSocket`
  /// requires `url`, `appId` and `userId`), and a second, native-side rejection
  /// path would only produce a worse error message than the one JS already has.
  init?(configMap: NSDictionary) {
    guard let url = configMap["url"] as? String, !url.isEmpty else { return nil }
    guard let authToken = configMap["authToken"] as? String else { return nil }
    guard let appID = configMap["appId"] as? String, !appID.isEmpty else { return nil }
    guard let userID = configMap["userId"] as? String, !userID.isEmpty else { return nil }
    self.init(
      url: url,
      authToken: authToken,
      // RN-008: project_id comes from the JWT, falling back to the config value.
      projectID: (configMap["projectId"] as? String) ?? "",
      appID: appID,
      userID: userID,
      pollIntervalMs: (configMap["pollIntervalMs"] as? NSNumber)?.intValue ?? 0,
      displayNotifications: SocketDisplayRule(
        rawValue: (configMap["displayNotifications"] as? String) ?? "") ?? .whenUnhandled,
      sdkVersion: configMap["sdkVersion"] as? String)
  }
}