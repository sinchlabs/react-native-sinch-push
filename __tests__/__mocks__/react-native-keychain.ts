export const ACCESSIBLE = { AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY: 'AfterFirstUnlockThisDeviceOnly' };
export const _store = new Map<string, string>();
export async function getGenericPassword(opts: { service: string }) {
  const v = _store.get(opts.service);
  return v === undefined ? false : { username: 'token', password: v, service: opts.service };
}
export async function setGenericPassword(_username: string, password: string, opts: { service: string }) {
  _store.set(opts.service, password);
  return true;
}
export async function resetGenericPassword(opts: { service: string }) {
  _store.delete(opts.service);
  return true;
}
