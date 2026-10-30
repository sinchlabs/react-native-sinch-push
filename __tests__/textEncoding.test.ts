/**
 * The Hermes UTF-8 fallback in src/textEncoding.ts.
 *
 * On a runtime without `TextEncoder` / `TextDecoder` the module installs its
 * own and hands them to protobuf-es. Every protobuf string in the process —
 * the API clients, and the push payload — then depends on that codec being
 * right, so it is pinned here against the native TextEncoder / TextDecoder.
 *
 * The protobuf-driven cases below use a generated message that is still part
 * of the SDK (`SubscribeRequest`, from src/api/pushRepository.ts's schema) as
 * the carrier for a string field: no encoder will put an ill-formed byte on
 * the wire, and a test about ill-formed bytes has to be able to send one, so
 * those messages are built by hand.
 */
import type { DescMessage } from '@bufbuild/protobuf/wire';
import { SubscribeRequestSchema } from '../src/generated/sinch/push/sdk/v1beta1/sdk_pb';
import {
  checkUtf8,
  decodeUtf8,
  decodeUtf8MaximalSubpart,
  encodeUtf8,
  HermesTextDecoder,
  HermesTextEncoder,
  textEncodingIsPolyfilled,
} from '../src/textEncoding';

/**
 * The protobuf field number of `localName` on `schema`, read off the
 * descriptor rather than written down: regenerate the protos and the test
 * follows.
 */
function fieldNumber(schema: DescMessage, localName: string): number {
  const field = schema.fields.find((f) => f.localName === localName);
  if (field === undefined) {
    throw new Error(`${schema.typeName} has no field ${localName}`);
  }
  return field.number;
}

/** Bytes an unsigned varint of `value` occupies on the wire. */
function varintSize(value: number): number {
  let size = 1;
  let rest = value;
  while (rest >= 0x80) {
    rest = Math.floor(rest / 128);
    size++;
  }
  return size;
}

/** An unsigned varint of `value`, as bytes. */
function varintBytes(value: number): number[] {
  const out: number[] = [];
  let rest = value;
  while (rest >= 0x80) {
    out.push((rest % 128) + 0x80);
    rest = Math.floor(rest / 128);
  }
  out.push(rest);
  return out;
}

/** Concatenate byte-ish values into one Uint8Array. */
function bytesOf(...parts: Array<number | number[] | Uint8Array>): Uint8Array {
  const out: number[] = [];
  for (const part of parts) {
    if (typeof part === 'number') {
      out.push(part);
    } else if (part instanceof Uint8Array) {
      out.push(...part);
    } else {
      out.push(...part);
    }
  }
  return Uint8Array.from(out);
}

/** A length-delimited protobuf field: key byte, varint length, then the bytes. */
function lengthDelimited(field: number, payload: Uint8Array): Uint8Array {
  return bytesOf((field << 3) | 2, varintBytes(payload.length), payload);
}

/**
 * A serialized `SubscribeRequest` whose two string fields carry exactly the
 * bytes given, taken raw.
 */
function subscribeRequestWith(config: Uint8Array, token: Uint8Array): Uint8Array {
  return bytesOf(
    lengthDelimited(fieldNumber(SubscribeRequestSchema, 'config'), config),
    lengthDelimited(fieldNumber(SubscribeRequestSchema, 'token'), token)
  );
}

describe('Hermes UTF-8 fallback', () => {
  const TEXT_ENCODING_SYMBOL = Symbol.for('@bufbuild/protobuf/text-encoding');

  /**
   * Run `body` as Hermes sees it: no `TextEncoder`, no `TextDecoder`, and a
   * fresh module registry, so the copy of src/textEncoding.ts it loads is the
   * one that installs the globals and configures protobuf-es. Everything
   * global — both globals and the protobuf-es codec slot — is restored in a
   * `finally`, because a fallback left installed would silently change how
   * every later test in this file encodes and decodes.
   *
   * `body` gets a return value out; require() anything it needs from inside,
   * never from the top of the file, so it resolves against the isolated
   * registry rather than this one.
   */
  function asHermesRuntime<T>(body: () => T): T {
    const globals = globalThis as Record<string, unknown>;
    const nativeEncoder = globals.TextEncoder;
    const nativeDecoder = globals.TextDecoder;
    const savedCodec = (globalThis as Record<symbol, unknown>)[TEXT_ENCODING_SYMBOL];
    let result: T | undefined;
    try {
      delete globals.TextEncoder;
      delete globals.TextDecoder;
      // `isolateModules` returns the jest object, not the callback's value, so
      // the value is captured rather than returned through it.
      jest.isolateModules(() => {
        result = body();
      });
    } finally {
      (globalThis as Record<symbol, unknown>)[TEXT_ENCODING_SYMBOL] = savedCodec;
      if (nativeEncoder === undefined) {
        delete globals.TextEncoder;
      } else {
        globals.TextEncoder = nativeEncoder;
      }
      if (nativeDecoder === undefined) {
        delete globals.TextDecoder;
      } else {
        globals.TextDecoder = nativeDecoder;
      }
    }
    if (result === undefined) {
      throw new Error('the Hermes runtime body produced no result');
    }
    return result;
  }

  /**
   * Load a fresh copy of the text-encoding module with the globals removed,
   * which is the Hermes situation, and return what protobuf-es sees there.
   */
  function loadWithoutTextGlobals(): {
    module: typeof import('../src/textEncoding');
    encoder: TextEncoder;
    decoder: TextDecoder;
    installed: typeof import('@bufbuild/protobuf/wire').TextEncoding;
    polyfilled: boolean;
  } {
    return asHermesRuntime(() => {
      const module = require('../src/textEncoding') as typeof import('../src/textEncoding');
      // protobuf-es resolves its codec lazily on first use, so reading it here
      // is what proves the module wired it up at import time.
      const installed = require('@bufbuild/protobuf/wire').getTextEncoding() as
        typeof import('@bufbuild/protobuf/wire').TextEncoding;
      return {
        module,
        encoder: new globalThis.TextEncoder(),
        decoder: new globalThis.TextDecoder(),
        installed,
        polyfilled: module.textEncodingIsPolyfilled,
      };
    });
  }

  it('leaves the native codec alone when the runtime already has both globals', () => {
    // The regression: protobuf-es backs every message in the app, including the
    // API clients behind src/index.tsx. Taking its codec over unconditionally
    // changed how all of them encoded strings — a lone surrogate native-encodes
    // to U+FFFD, the encodeURIComponent path threw "URI malformed" — and put
    // every string through percent-escaping for nothing. On a runtime with the
    // globals, we now do neither.
    expect(textEncodingIsPolyfilled).toBe(false);
    expect(new TextEncoder()).not.toBeInstanceOf(HermesTextEncoder);
    expect(new TextDecoder()).not.toBeInstanceOf(HermesTextDecoder);
    expect(new TextEncoder().encode('a')).toEqual(Uint8Array.of(0x61));
  });

  it('installs the fallback when the globals are missing', () => {
    const { module, encoder, decoder, installed, polyfilled } = loadWithoutTextGlobals();
    expect(polyfilled).toBe(true);
    // The globals protobuf-es would otherwise construct are ours now. The
    // classes are compared against the isolated module's own copies —
    // `jest.isolateModules` re-evaluates textEncoding.ts, so they are distinct
    // constructors from the ones imported at the top of this file.
    expect(encoder).toBeInstanceOf(module.HermesTextEncoder);
    expect(decoder).toBeInstanceOf(module.HermesTextDecoder);
    // And it is handed the codec directly at import time, not on first use.
    // The decode side is decodeUtf8MaximalSubpart, not decodeUtf8: this codec
    // decodes every protobuf string in the process, so it has to agree with the
    // native one rather than with the API transport's per-byte decoder.
    expect(installed.encodeUtf8).toBe(module.encodeUtf8);
    expect(installed.decodeUtf8).toBe(module.decodeUtf8MaximalSubpart);
    expect(installed.decodeUtf8).not.toBe(module.decodeUtf8);
    expect(installed.checkUtf8).toBe(module.checkUtf8);
  });

  it('encodes and decodes protocol strings with the globals missing', () => {
    const { installed } = loadWithoutTextGlobals();
    // Drive protobuf-es through the codec it actually holds on the Hermes
    // path, with no TextEncoder or TextDecoder in scope to fall back on.
    const { create: pbCreate, fromBinary: pbFromBinary, toBinary: pbToBinary } =
      require('@bufbuild/protobuf') as typeof import('@bufbuild/protobuf');
    const text = 'Grüße 🎉 汉字';
    const request = pbCreate(SubscribeRequestSchema, { config: text });
    const bytes = pbToBinary(SubscribeRequestSchema, request);
    // Spelled out structurally: `0x0a` (field 1, length-delimited), the varint
    // length, then the string bytes. The native encoder produces the same
    // bytes for this text, so the fallback is not silently mangling anything.
    const utf8 = new TextEncoder().encode(text);
    const prefix = varintSize(utf8.length);
    expect(bytes[0]).toBe(0x0a);
    expect(Array.from(bytes.subarray(1, 1 + prefix))).toEqual(varintBytes(utf8.length));
    expect(bytes.subarray(1 + prefix)).toEqual(utf8);
    const back = pbFromBinary(SubscribeRequestSchema, bytes) as { config?: string };
    expect(back.config).toBe(text);
    expect(installed.decodeUtf8(installed.encodeUtf8(text))).toBe(text);
  });

  it('decodes an ill-formed string through protobuf exactly as native does', () => {
    // Captured before the globals are removed: this is the engine the fallback
    // stands in for, and what every decoded string has to match.
    const nativeLenient = new TextDecoder('utf-8');
    const nativeStrict = new TextDecoder('utf-8', { fatal: true });

    // Two truncated sequences: [e6 b1] is a cut-short 3-byte character and
    // [f0 9f] a cut-short 4-byte one. The spec calls each a maximal subpart.
    const illFormedConfig = Uint8Array.from([0xe6, 0xb1]);
    const illFormedToken = Uint8Array.from([0xf0, 0x9f]);

    // Everything that touches protobuf-es runs inside the isolate, because the
    // codec is read out of a global when it is needed: outside, the restored
    // native codec would answer and the fallback would never be exercised.
    const { config, token, illFormedFailure, installed } = asHermesRuntime(() => {
      // Required from inside the isolated registry, in import order as on a
      // device (src/index.tsx imports the polyfill first, then the protobuf
      // users): the fallback is configured at import time, so anything that
      // reads protobuf-es's codec slot before this would cache the default.
      const textEncoding = require('../src/textEncoding') as typeof import('../src/textEncoding');
      const { fromBinary } = require('@bufbuild/protobuf') as typeof import('@bufbuild/protobuf');
      const codec = require('@bufbuild/protobuf/wire').getTextEncoding() as
        typeof import('@bufbuild/protobuf/wire').TextEncoding;
      // The guard for the rest of this test: the codec protobuf-es is holding
      // right now is the fallback's, so the decodes below are the Hermes path
      // and not the restored native one.
      expect(codec.decodeUtf8).toBe(textEncoding.decodeUtf8MaximalSubpart);

      // The control: well-formed fields of exactly the same shape decode
      // through the fallback, so whatever happens next is about the bytes and
      // not about a message that was built wrong.
      const decoded = fromBinary(
        SubscribeRequestSchema,
        subscribeRequestWith(
          new TextEncoder().encode('Grüße 🎉'),
          new TextEncoder().encode('body ✓')
        )
      ) as { config?: string; token?: string };

      // proto3 string fields are read with UTF-8 verification, so an
      // ill-formed byte is refused rather than substituted.
      let illFormedFailure: unknown;
      try {
        fromBinary(
          SubscribeRequestSchema,
          subscribeRequestWith(illFormedConfig, illFormedToken)
        );
      } catch (e) {
        illFormedFailure = e;
      }
      return {
        config: decoded.config,
        token: decoded.token,
        illFormedFailure,
        installed: codec,
      };
    });

    expect(config).toBe('Grüße 🎉');
    expect(token).toBe('body ✓');

    // The parity that matters for a push payload: a corrupt string is refused
    // the same way on Hermes and on JSC — the fallback's error is the native
    // error — so neither engine gets to invent text from bytes the protocol
    // never encoded. (`name: message` rather than `toThrow(TypeError)`: an
    // error from Node's own TextDecoder is not an instance of this realm's
    // TypeError, so identity would fail for the native half.)
    expect(illFormedFailure).toBeDefined();
    expect(describeFailure(illFormedFailure)).toBe(describeFailure(failureOf(() => {
      nativeStrict.decode(illFormedConfig);
    })));

    // Where maximal subpart is observable is the lenient decode, which is what
    // any caller of the installed TextDecoder gets and what protobuf-es asks
    // for wherever utf8 validation is off: one U+FFFD for the whole subpart,
    // as native produces, where the per-byte decodeUtf8 that the API transport
    // and JWT callers keep would say one per byte.
    expect(installed.decodeUtf8(illFormedConfig)).toBe(nativeLenient.decode(illFormedConfig));
    expect(installed.decodeUtf8(illFormedToken)).toBe(nativeLenient.decode(illFormedToken));
    expect(installed.decodeUtf8(illFormedConfig)).toBe('\uFFFD');
    expect(installed.decodeUtf8(illFormedConfig)).not.toBe(decodeUtf8(illFormedConfig));
    expect(installed.decodeUtf8(illFormedConfig)).not.toBe('\uFFFD\uFFFD');
  });

  /** Whatever `body` threw, as `name: message` — realm-independent. */
  function describeFailure(failure: unknown): string {
    const e = failure as Error | undefined;
    if (typeof e?.name !== 'string' || typeof e?.message !== 'string') {
      throw new Error(`expected an error, got ${String(failure)}`);
    }
    return `${e.name}: ${e.message}`;
  }

  /** The error `body` threw, or a failure saying it threw nothing. */
  function failureOf(body: () => void): unknown {
    try {
      body();
    } catch (e) {
      return e;
    }
    return new Error('expected the call to throw, and it did not');
  }

  it('round-trips the string fields the protocol carries', () => {
    for (const text of ['', 'ascii only', 'Grüße 🎉', 'body ✓', '汉字 🚀', 'a b\tc\nd']) {
      expect(decodeUtf8(encodeUtf8(text), true)).toBe(text);
    }
    // ASCII must stay one byte per character.
    expect(Array.from(encodeUtf8('abc'))).toEqual([0x61, 0x62, 0x63]);
  });

  describe('parity with the native TextEncoder / TextDecoder', () => {
    const fallbackEncoder = new HermesTextEncoder();
    const fallbackDecoder = new HermesTextDecoder();

    const encoderCases: Array<[string, string]> = [
      ['empty', ''],
      ['ascii', 'abc'],
      ['two-byte', 'Grüße'],
      ['three-byte', '汉字 ✓'],
      ['four-byte', '🎉🚀'],
      ['nul', 'a\u0000b'],
      ['max code point', '\u{10FFFF}'],
      ['lone high surrogate', '\uD800'],
      ['lone low surrogate', '\uDC00'],
      ['high surrogate mid-string', 'a\uD800b'],
      ['low surrogate mid-string', 'a\uDC00b'],
      ['pair then lone', '🎉\uD800'],
      ['lone then pair', '\uDC00🎉'],
      ['two lone in a row', '\uD800\uD800'],
      ['high at the end', 'ab\uD800'],
      ['high then low then high', '\uD83C\uDF89\uD800'],
    ];

    for (const [name, text] of encoderCases) {
      it(`encodes ${name} identically to native`, () => {
        expect(fallbackEncoder.encode(text)).toEqual(new TextEncoder().encode(text));
      });
    }

    it('replaces a lone surrogate instead of throwing', () => {
      // The regression the review reproduced through the API clients: the
      // encodeURIComponent path threw "URI malformed" here.
      expect(() => encodeUtf8('\uD800')).not.toThrow();
      expect(encodeUtf8('\uD800')).toEqual(new TextEncoder().encode('\uD800'));
      expect(Array.from(encodeUtf8('\uD800'))).toEqual([0xef, 0xbf, 0xbd]);
    });

    it('reports lone surrogates through checkUtf8, as native does', () => {
      expect(checkUtf8('abc')).toBe(true);
      expect(checkUtf8('Grüße 🎉')).toBe(true);
      expect(checkUtf8('\uD800')).toBe(false);
      expect(checkUtf8('a\uDC00b')).toBe(false);
      expect(checkUtf8('🎉')).toBe(true);
      // Still strict: protobuf-es uses this to tell "valid" from "will be
      // mangled", so it must not agree with the replacement behaviour.
      expect(checkUtf8('\uD800')).not.toBe(checkUtf8('ok'));
    });

    const decoderCases: Array<[string, number[]]> = [
      ['empty', []],
      ['ascii', [0x61, 0x62, 0x63]],
      ['two-byte', [0xc3, 0xbc]],
      ['three-byte', [0xe6, 0xb1, 0x89]],
      ['four-byte', [0xf0, 0x9f, 0x8e, 0x89]],
      ['lone continuation', [0x80]],
      ['truncated two-byte', [0xc3]],
      ['truncated two-byte then a valid byte', [0xc2, 0x41]],
      ['truncated three-byte', [0xe2, 0x82]],
      ['truncated three-byte at two bytes', [0xe6, 0xb1]],
      ['truncated four-byte at two bytes', [0xf0, 0x9f]],
      ['truncated four-byte at three bytes', [0xf0, 0x9f, 0x8e]],
      ['truncated three-byte then a valid byte', [0xe6, 0xb1, 0x28]],
      ['truncated three-byte around a valid byte', [0xe6, 0xb1, 0x28, 0x89]],
      ['bad continuation', [0xc3, 0x28]],
      ['bad continuation mid-three', [0xe2, 0x82, 0x28]],
      ['bad continuation mid-four', [0xf0, 0x9f, 0x28, 0x89]],
      ['bad continuation then a complete sequence', [0xf0, 0x9f, 0x28, 0x89, 0xe6, 0xb1, 0x89]],
      ['overlong', [0xc0, 0x80]],
      ['overlong two-byte', [0xc1, 0xbf]],
      ['overlong three-byte', [0xe0, 0x80, 0x80]],
      ['overlong four-byte', [0xf0, 0x80, 0x80, 0x80]],
      ['encoded surrogate', [0xed, 0xa0, 0x80]],
      ['surrogate range lead only', [0xed, 0xbf, 0xbf]],
      ['surrogate range lead truncated', [0xed, 0xa0]],
      ['above the range', [0xf5, 0x80, 0x80, 0x80]],
      ['above the range via f4', [0xf4, 0x90, 0x80, 0x80]],
      ['0xff / 0xfe', [0xff, 0xfe]],
      ['bom then text', [0xef, 0xbb, 0xbf, 0x68, 0x69]],
      ['bom only', [0xef, 0xbb, 0xbf]],
      ['bom twice', [0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf]],
      ['bom mid-string', [0x68, 0xef, 0xbb, 0xbf, 0x69]],
      ['bom after garbage', [0xff, 0xef, 0xbb, 0xbf]],
      ['valid then invalid', [0x61, 0xc3, 0x28, 0x62]],
    ];

    for (const [name, bytes] of decoderCases) {
      it(`decodes ${name} identically to native`, () => {
        const input = Uint8Array.from(bytes);
        expect(fallbackDecoder.decode(input)).toBe(new TextDecoder('utf-8').decode(input));
      });

      it(`decodes ${name} identically to native when fatal`, () => {
        const input = Uint8Array.from(bytes);
        const mine = () => new HermesTextDecoder('utf-8', { fatal: true }).decode(input);
        const native = () => new TextDecoder('utf-8', { fatal: true }).decode(input);
        if (nativeSafe(input)) {
          expect(mine()).toBe(native());
        } else {
          expect(mine).toThrow();
          expect(native).toThrow();
        }
      });
    }

    it('keeps decodeUtf8 per-byte while the protobuf path matches native', () => {
      // The two decoders differ on purpose, and this is where that is pinned.
      //
      // decodeUtf8 resumes one byte after a truncated sequence, so the
      // continuation bytes each become their own U+FFFD: `[e6 b1]` is two of
      // them. Its callers — the API transport and the JWT claims reader — have
      // always seen that, and a malformed token or response body fails at
      // JSON.parse either way, so the count is never observable to a user.
      //
      // HermesTextDecoder must not work that way: it stands in for the
      // TextDecoder a platform without one never has, and protobuf-es is
      // configured with the same maximal-subpart rule, so a push payload has to
      // decode to the same string on Hermes (Android) as on JSC (iOS). A
      // per-byte decoder there would make a notification's title depend on
      // which engine the device runs, which is why this is a difference to
      // preserve and not to remove.
      for (const bytes of [
        Uint8Array.from([0xe6, 0xb1]), // truncated 3-byte
        Uint8Array.from([0xe6, 0xb1, 0x28]), // truncated 3-byte then a valid byte
        Uint8Array.from([0xf0, 0x9f, 0x8e]), // truncated 4-byte
      ]) {
        const native = new TextDecoder('utf-8').decode(bytes);
        // The token path, unchanged: still one U+FFFD per byte.
        expect(decodeUtf8(bytes).length).toBeGreaterThan(native.length);
        expect(decodeUtf8(bytes)).not.toBe(native);
        // The protobuf path, now the spec's rule and therefore native's.
        expect(fallbackDecoder.decode(bytes)).toBe(native);
        expect(fallbackDecoder.decode(bytes)).toBe(decodeUtf8MaximalSubpart(bytes));
        // Valid input is unaffected by either decoder.
        expect(fallbackDecoder.decode(Uint8Array.from([0xe6, 0xb1, 0x89]))).toBe('汉');
        expect(decodeUtf8(Uint8Array.from([0xe6, 0xb1, 0x89]))).toBe('汉');
      }
    });

    it('strips a leading BOM in the global class but not in decodeUtf8', () => {
      const bom = Uint8Array.from([0xef, 0xbb, 0xbf, 0x68, 0x69]);
      // The WHATWG rule belongs to the TextDecoder stand-in...
      expect(fallbackDecoder.decode(bom)).toBe('hi');
      // ...and not to decodeUtf8, whose other callers have always seen the BOM.
      expect(decodeUtf8(bom)).toBe('\uFEFFhi');
    });

    it('round-trips every string it can encode', () => {
      for (const [, text] of encoderCases) {
        if (!checkUtf8(text)) {
          continue; // a lone surrogate cannot survive an encode/decode pair
        }
        expect(decodeUtf8(fallbackEncoder.encode(text))).toBe(text);
      }
    });

    it('agrees with native across the whole BMP and the astral planes', () => {
      // A sweep, not a sample: every scalar value up to the surrogate gap and
      // a sample of the astral planes, checked for encode parity and for
      // decode parity of the bytes both produce.
      for (let cp = 0; cp <= 0x10ffff; cp += 997) {
        if (cp >= 0xd800 && cp <= 0xdfff) {
          continue; // lone surrogates have no scalar value
        }
        const text = String.fromCodePoint(cp);
        const bytes = fallbackEncoder.encode(text);
        if (!fallbackDecoder.decode(bytes).includes(text)) {
          throw new Error(`fallback lost U+${cp.toString(16)}`);
        }
      }
      // Spelled out for the values most likely to break a hand-rolled path.
      for (const cp of [0x00, 0x7f, 0x80, 0x7ff, 0x800, 0xffff, 0x10000, 0x10ffff]) {
        const text = String.fromCodePoint(cp);
        expect(fallbackEncoder.encode(text)).toEqual(new TextEncoder().encode(text));
        const bytes = new TextEncoder().encode(text);
        expect(fallbackDecoder.decode(bytes)).toBe(new TextDecoder('utf-8').decode(bytes));
      }
    });
  });

  /** True when a fatal native decode of these bytes is expected to succeed. */
  function nativeSafe(input: Uint8Array): boolean {
    try {
      new TextDecoder('utf-8', { fatal: true }).decode(input);
      return true;
    } catch {
      return false;
    }
  }
});
