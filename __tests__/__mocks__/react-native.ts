const Platform = { OS: 'ios', select: (obj: any) => obj.ios ?? obj.default };
const installationId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
// The persisted relay switch, as a plain flag: off until something opts in.
let relayEnabled = false;
const NativeModules = {
  SinchPush: {
    setRelayEnabled: async (enabled: boolean) => {
      relayEnabled = enabled;
    },
    isRelayEnabled: async () => relayEnabled,
    getDeviceToken: async () => ({}),
    registerForToken: async () => undefined,
    getInstallationId: async () => installationId,
    getDeviceInfo: async () => ({
      installationId,
      platform: 'ios',
      osVersion: '17.5',
      sdkVersion: 'rn-sinch-push/1.1.0',
      bundleId: 'com.example.app',
      backgroundService: 'UNSUPPORTED',
    }),
    getReportOutbox: async () => [],
    removeReportOutboxEntries: async () => undefined,
    clearReportOutbox: async () => undefined,
    configureSharedReports: async () => undefined,
    setSharedReportSession: async () => undefined,
    addListener: () => {},
    removeListeners: () => {},
  },
};
type AppStateListener = (state: string) => void;
const appStateListeners: AppStateListener[] = [];
const AppState = {
  currentState: 'active',
  addEventListener(_type: 'change', listener: AppStateListener) {
    appStateListeners.push(listener);
    return {
      remove() {
        const i = appStateListeners.indexOf(listener);
        if (i >= 0) appStateListeners.splice(i, 1);
      },
    };
  },
};
type Listener = (event: string, payload: any) => void;
const globalListeners: Record<string, Listener[]> = {};
function NativeEventEmitter(_module?: unknown) {
  return {
    addListener(event: string, listener: Listener) {
      (globalListeners[event] ||= []).push(listener);
      return {
        remove() {
          const list = globalListeners[event] || [];
          const i = list.indexOf(listener);
          if (i >= 0) list.splice(i, 1);
        },
      };
    },
    removeAllListeners(event?: string) { if (event) delete globalListeners[event]; else for (const k of Object.keys(globalListeners)) delete globalListeners[k]; },
    emit(event: string, payload: any) { (globalListeners[event] || []).forEach((l) => l(event, payload)); },
  };
}
(global as any).__fireSinchPushEvent = (event: string, payload: any) => { (globalListeners[event] || []).forEach((l) => l(payload)); };
(global as any).__sinchPushListenerCount = () => Object.fromEntries(Object.entries(globalListeners).map(([k, v]) => [k, v.length]));
(global as any).__setAppState = (state: string) => {
  AppState.currentState = state;
  appStateListeners.slice().forEach((l) => l(state));
};
(global as any).__sinchPushAppStateListenerCount = () => appStateListeners.length;
module.exports = { Platform, NativeModules, NativeEventEmitter, AppState };
