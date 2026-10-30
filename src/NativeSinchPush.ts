import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

export interface Spec extends TurboModule {
  getDeviceToken(): Promise<Object>;

  registerForToken(): Promise<void>;

  /** Returns the persisted installation UUID; see `getInstallationId`. */
  getInstallationId(): Promise<string>;

  /** Returns the device facts `Subscribe` and `Hello` carry; see `getDeviceInfo`. */
  getDeviceInfo(): Promise<Object>;

  /** Applies and persists the relay switch; see `setRelayEnabled`. */
  setRelayEnabled(enabled: boolean): Promise<void>;

  /** Whether the relay is on for this install; see `isRelayEnabled`. */
  isRelayEnabled(): Promise<boolean>;

  // --- Persistent WebSocket delivery channel -------------------------------
  // See docs/push-socket-protocol.md. `config` is a PushSocketConfig-shaped
  // object; on Android this starts a foreground service that owns the socket.

  startPushSocket(config: Object): Promise<void>;

  stopPushSocket(): Promise<void>;

  getPushSocketState(): Promise<Object>;

  getPendingPushMessages(): Promise<Object[]>;

  clearPendingPushMessages(): Promise<void>;

  displayNotification(title: string, body: string, data: Object): Promise<void>;

  /**
   * Report DISPLAYED / DISMISSED for a message the host surfaced itself. The
   * native client owns the socket on both platforms, so this is what the public
   * `reportPushMessageStatus` reaches: iOS queues it in the persisted outbox
   * when the socket is suspended, Android forwards it to the socket owner
   * (outbox too while disconnected).
   *
   * Rejects with `E_INVALID_STATUS` for anything but 'displayed' / 'dismissed'
   * and with `E_NOT_RUNNING` when no socket owner exists.
   */
  reportPushMessageStatus(messageId: string, status: string): Promise<void>;

  /**
   * Tell native whether the host registered an in-app handler. It is what the
   * `whenUnhandled` display rule keys on: with a handler registered the native
   * client emits the event and stays quiet, so the app renders its own UI.
   */
  setSocketHandlerRegistered(registered: boolean): Promise<void>;

  // --- Provider-push delivery reports ---------------------------------------
  // A provider push the relay had not delivered is queued natively; JS reads the
  // queue back, reports it and drops the entries it reported.

  /**
   * The queued delivery reports, oldest first. `enqueuedAt` is the epoch
   * milliseconds the entry was queued at.
   */
  getReportOutbox(): Promise<
    ReadonlyArray<{
      messageId: string;
      subscriberId: string;
      enqueuedAt: number;
    }>
  >;

  /** Drops the named entries from the queue; the rest keep their place. */
  removeReportOutboxEntries(
    entries: ReadonlyArray<{ messageId: string; subscriberId: string }>,
  ): Promise<void>;

  /** Drops every queued entry. */
  clearReportOutbox(): Promise<void>;

  /**
   * iOS only. Answers a `SinchPushBackgroundWake` event: JS has run the report
   * outbox flush for the wake, and native may call the system completion handler of the
   * `didReceiveRemoteNotification` that queued the report. `sent` means "the
   * outbox is empty now" (so also true when there was nothing to send), not that
   * this wake's report was acknowledged by the server. Native calls it
   * itself after 25 s when JS never answers. A no-op on Android, which never
   * emits the event.
   */
  completeBackgroundWake(wakeId: string, sent: boolean): Promise<void>;

  /**
   * iOS only. Sets the App Group shared with the Notification Service Extension
   * (`ios.appGroup` of `initialize`), or `null` for none; persisted natively. A
   * no-op on Android.
   */
  configureSharedReports(appGroup: string | null): Promise<void>;

  /**
   * Mirrors the minimal report credential
   * `{ accessToken, reportBaseURL, userId, appId }` to native storage; `null`
   * clears it. Never the HMAC secret. On iOS it goes to the App Group container
   * when one is configured, for the Notification Service Extension and for
   * background uploads; on Android it goes to app-private storage, so the
   * messaging service can upload a ReportEvents DELIVERED report with the
   * process dead. JS calls it after every JWT store, and clears it on
   * `removeIdentity` and when `initialize` finds no stored JWT for its account.
   * Nothing re-mints the JWT: once its `exp` has passed, native uploads stop
   * until the next `setIdentity`.
   */
  setSharedReportSession(record: Object | null): Promise<void>;

  addListener(eventName: string): void;

  removeListeners(count: number): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('SinchPush');
