import { create, toBinary } from '@bufbuild/protobuf';
import {
  AppMessageSchema,
  type AppMessage,
} from '../src/generated/sinch/conversationapi/type/conversation_message_pb';
import { onInAppMessageHandler } from '../src/api/inAppMessage';

function uint8ToBase64(bytes: Uint8Array): string {
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i] as number);
  return Buffer.from(bin, 'binary').toString('base64');
}

function emitPushReceiveEvent(data: Record<string, string>) {
  const ev = {
    data,
    source: 'apns',
    title: undefined,
    body: undefined,
  };
  (global as any).__fireSinchPushEvent('SinchPush:onPushReceived', ev);
}

describe('onInAppMessageHandler', () => {
  it('does not fire when the push has no protobufPayload', () => {
    const calls: unknown[] = [];
    const sub = onInAppMessageHandler((m) => calls.push(m));

    emitPushReceiveEvent({ source: 'apns', unrelated: 'noise' });

    expect(calls).toHaveLength(0);
    sub.remove();
  });

  it('decodes a text message', () => {
    const msg: AppMessage = create(AppMessageSchema, {
      message: { case: 'textMessage', value: { text: 'hello' } },
    });
    const payload = uint8ToBase64(toBinary(AppMessageSchema, msg));

    const calls: any[] = [];
    const sub = onInAppMessageHandler((m) => calls.push(m));

    emitPushReceiveEvent({ protobufPayload: payload });

    expect(calls).toHaveLength(1);
    expect(calls[0]).toEqual({ kind: 'text', text: 'hello' });
    sub.remove();
  });

  it('decodes a media message', () => {
    const msg = create(AppMessageSchema, {
      message: { case: 'mediaMessage', value: { url: 'https://cdn.example/image.png' } },
    });
    const payload = uint8ToBase64(toBinary(AppMessageSchema, msg));

    const calls: any[] = [];
    const sub = onInAppMessageHandler((m) => calls.push(m));

    emitPushReceiveEvent({ protobufPayload: payload });

    expect(calls).toHaveLength(1);
    expect(calls[0]).toEqual({ kind: 'media', url: 'https://cdn.example/image.png' });
    sub.remove();
  });

  it('decodes a location message', () => {
    const msg = create(AppMessageSchema, {
      message: {
        case: 'locationMessage',
        value: {
          title: 'Sinch HQ',
          label: 'Stockholm',
          coordinates: { latitude: 59.33, longitude: 18.06 },
        },
      },
    });
    const payload = uint8ToBase64(toBinary(AppMessageSchema, msg));

    const calls: any[] = [];
    const sub = onInAppMessageHandler((m) => calls.push(m));

    emitPushReceiveEvent({ protobufPayload: payload });

    expect(calls).toHaveLength(1);
    expect(calls[0].kind).toBe('location');
    expect(calls[0].title).toBe('Sinch HQ');
    expect(calls[0].label).toBe('Stockholm');
    expect(calls[0].latitude).toBeCloseTo(59.33, 5);
    expect(calls[0].longitude).toBeCloseTo(18.06, 5);
    sub.remove();
  });

  it('decodes a choice message with text choices', () => {
    const msg = create(AppMessageSchema, {
      message: {
        case: 'choiceMessage',
        value: {
          textMessage: { text: 'Pick one' },
          choices: [
            { choice: { case: 'textMessage', value: { text: 'Yes' } }, postbackData: 'yes' },
            { choice: { case: 'textMessage', value: { text: 'No' } }, postbackData: 'no' },
          ],
        },
      },
    });
    const payload = uint8ToBase64(toBinary(AppMessageSchema, msg));

    const calls: any[] = [];
    const sub = onInAppMessageHandler((m) => calls.push(m));

    emitPushReceiveEvent({ protobufPayload: payload });

    expect(calls).toHaveLength(1);
    expect(calls[0].kind).toBe('choice');
    expect(calls[0].text).toBe('Pick one');
    expect(calls[0].choices).toEqual([
      { title: 'Yes', value: 'yes' },
      { title: 'No', value: 'no' },
    ]);
    sub.remove();
  });

  it('decodes a card message', () => {
    const msg = create(AppMessageSchema, {
      message: {
        case: 'cardMessage',
        value: {
          title: 'Sinch',
          description: 'Cloud communications',
          mediaMessage: { url: 'https://cdn.example/card.png' },
          choices: [{ choice: { case: 'urlMessage', value: { title: 'Open', url: 'https://x' } } }],
        },
      },
    });
    const payload = uint8ToBase64(toBinary(AppMessageSchema, msg));

    const calls: any[] = [];
    const sub = onInAppMessageHandler((m) => calls.push(m));

    emitPushReceiveEvent({ protobufPayload: payload });

    expect(calls).toHaveLength(1);
    expect(calls[0].kind).toBe('card');
    expect(calls[0].title).toBe('Sinch');
    expect(calls[0].url).toBe('https://cdn.example/card.png');
    expect(calls[0].choices).toEqual([{ title: 'Open', value: 'https://x' }]);
    sub.remove();
  });

  it('decodes a carousel message', () => {
    const msg = create(AppMessageSchema, {
      message: {
        case: 'carouselMessage',
        value: {
          cards: [
            {
              title: 'Card 1',
              description: 'first',
              mediaMessage: { url: 'https://cdn.example/c1.png' },
              choices: [],
            },
            {
              title: 'Card 2',
              mediaMessage: { url: 'https://cdn.example/c2.png' },
              choices: [],
            },
          ],
          choices: [],
        },
      },
    });
    const payload = uint8ToBase64(toBinary(AppMessageSchema, msg));

    const calls: any[] = [];
    const sub = onInAppMessageHandler((m) => calls.push(m));

    emitPushReceiveEvent({ protobufPayload: payload });

    expect(calls).toHaveLength(1);
    expect(calls[0].kind).toBe('carousel');
    expect(calls[0].cards).toHaveLength(2);
    expect(calls[0].cards[0].title).toBe('Card 1');
    expect(calls[0].cards[0].url).toBe('https://cdn.example/c1.png');
    sub.remove();
  });

  it('does not throw on bad base64', () => {
    const calls: unknown[] = [];
    const sub = onInAppMessageHandler((m) => calls.push(m));

    expect(() =>
      emitPushReceiveEvent({ protobufPayload: 'not-valid-base64###' }),
    ).not.toThrow();

    expect(calls).toHaveLength(0);
    sub.remove();
  });
});
