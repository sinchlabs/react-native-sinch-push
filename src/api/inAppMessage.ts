import { fromBinary } from '@bufbuild/protobuf';
import {
  AppMessageSchema,
  type AppMessage,
  type CardMessage,
  type Choice,
} from '../generated/sinch/conversationapi/type/conversation_message_pb';
import { subscribeToPush } from './eventBus';
import type {
  InAppMessage,
  InAppMessageCard,
  InAppMessageChoice,
  InAppMessageHandler,
  SinchPushMessage,
  Subscription,
} from '../types';

/**
 * Subscribe to decoded in-app messages.
 *
 * Wraps `onPushReceiveHandler` and filters for `data.protobufPayload`, so it
 * never fires for ordinary pushes. The native bridge forwards the raw base64
 * string as-is (iOS keeps every non-`aps` key as a string; Android forwards
 * the FCM data map verbatim) — decoding happens here in JS.
 */
export function onInAppMessageHandler(
  handler: InAppMessageHandler
): Subscription {
  return subscribeToPush((message: SinchPushMessage) => {
    const payload = message.data?.protobufPayload;
    if (!payload) {
      return;
    }
    try {
      const decoded = fromBinary(AppMessageSchema, uint8FromBase64(payload));
      const out = convert(decoded);
      if (out) {
        handler(out);
      }
    } catch (e) {
      // eslint-disable-next-line no-console
      console.warn('[sinch] in-app-message decode failed', e);
    }
  });
}

function uint8FromBase64(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) {
    out[i] = bin.charCodeAt(i);
  }
  return out;
}

/**
 * Maps the `AppMessage.message` oneof onto the `InAppMessage` union. Cases the
 * Swift controller does not handle (template, contact info, list) return null.
 */
function convert(m: AppMessage): InAppMessage | null {
  switch (m.message.case) {
    case 'textMessage':
      return { kind: 'text', text: m.message.value.text };
    case 'mediaMessage':
      return { kind: 'media', url: m.message.value.url };
    case 'locationMessage':
      return {
        kind: 'location',
        title: m.message.value.title || undefined,
        label: m.message.value.label || undefined,
        latitude: m.message.value.coordinates?.latitude ?? 0,
        longitude: m.message.value.coordinates?.longitude ?? 0,
      };
    case 'choiceMessage':
      return {
        kind: 'choice',
        text: m.message.value.textMessage?.text ?? '',
        choices: m.message.value.choices.map(toChoice),
      };
    case 'cardMessage':
      return { kind: 'card', ...toCard(m.message.value) };
    case 'carouselMessage':
      return {
        kind: 'carousel',
        cards: m.message.value.cards.map(toCard),
        choices: m.message.value.choices.map(toChoice),
      };
    default:
      return null;
  }
}

function toCard(c: CardMessage): InAppMessageCard {
  return {
    title: c.title,
    description: c.description || undefined,
    choices: c.choices.map(toChoice),
    url: c.mediaMessage?.url ?? '',
  };
}

/**
 * Flattens the proto `Choice` oneof to `{ title, value }`, following the Swift
 * `DefaultMessageDataSource.createChoicesArray` mapping.
 */
function toChoice(c: Choice): InAppMessageChoice {
  switch (c.choice.case) {
    case 'textMessage':
      return { title: c.choice.value.text, value: c.postbackData || undefined };
    case 'urlMessage':
      return { title: c.choice.value.title, value: c.choice.value.url };
    case 'callMessage':
      return { title: c.choice.value.title, value: c.choice.value.phoneNumber };
    case 'locationMessage':
      return {
        title: c.choice.value.title,
        value: c.choice.value.label || undefined,
      };
    default:
      return { title: '', value: c.postbackData || undefined };
  }
}
