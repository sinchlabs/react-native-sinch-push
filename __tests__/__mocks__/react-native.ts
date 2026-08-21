const Platform = { OS: 'ios', select: (obj: any) => obj.ios ?? obj.default };
const NativeModules = { SinchPush: { getDeviceToken: async () => ({}), registerForToken: async () => undefined, addListener: () => {}, removeListeners: () => {} } };
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
module.exports = { Platform, NativeModules, NativeEventEmitter };
