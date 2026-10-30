import CryptoJS from 'crypto-js';
import * as Keychain from 'react-native-keychain';
import type {SignedIdentity} from '@sinch/react-native-sinch-push';
import {config} from './config';
import {usesBackendSigning} from './configCheck';

const USER_SERVICE = 'sinch-push-example.user-id';

/** A random v4 UUID, uppercase (Hermes has no crypto.getRandomValues). */
export function newUserId(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    .replace(/[xy]/g, c => {
      const r = Math.floor(Math.random() * 16);
      return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
    })
    .toUpperCase();
}

export async function loadUserId(): Promise<string> {
  const stored = await Keychain.getGenericPassword({service: USER_SERVICE});
  return stored ? stored.password : saveUserId(newUserId());
}

export async function saveUserId(userId: string): Promise<string> {
  await Keychain.setGenericPassword('user', userId, {service: USER_SERVICE});
  return userId;
}

/**
 * Signs `userId` for setIdentity / removeIdentity: through your backend
 * (`signedUserIdUrl`: POST {userId} → {signedUserId}), or, DEMO ONLY, with the
 * secret from config.ts.
 */
export async function signIdentity(userId: string): Promise<SignedIdentity> {
  if (usesBackendSigning()) {
    const response = await fetch(config.signedUserIdUrl as string, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({userId}),
    });
    if (!response.ok) {
      throw new Error(`signedUserIdUrl answered HTTP ${response.status}`);
    }
    const {signedUserId} = await response.json();
    if (typeof signedUserId !== 'string' || !signedUserId) {
      throw new Error('signedUserIdUrl did not return {"signedUserId": "…"}');
    }
    return {userID: userId, signedUserID: signedUserId};
  }
  return {
    userID: userId,
    signedUserID: CryptoJS.HmacSHA512(userId, config.demoOnlyIdentitySecret as string).toString(
      CryptoJS.enc.Hex,
    ),
  };
}
