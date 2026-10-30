// @bufbuild/protobuf converts string fields to/from UTF-8 through the Text
// Encoding API, which Hermes does not ship. This module fills that gap, and
// only that gap.
//
// protobuf-es builds its codec lazily, from `new TextEncoder()` /
// `new TextDecoder()`, the first time it encodes or decodes a string. So the
// decision has to be made here, at import time, before the first frame is
// touched — but it must not be made unconditionally. Every protobuf message in
// the app runs through protobuf-es, including the API clients reached via
// src/index.tsx, and swapping the codec out from under all of them changes
// behaviour (a lone surrogate native-encodes to U+FFFD; encodeURIComponent
// throws "URI malformed") and puts every string through percent-escaping plus
// substring parsing for no measured gain. On a runtime that already ships the
// globals we therefore stay out of the way entirely.
//
// Which decoder that gap gets filled with depends on who is reading: this
// module carries two, decodeUtf8 (one U+FFFD per byte) and
// decodeUtf8MaximalSubpart (one per maximal subpart, as the spec and every
// native TextDecoder do). Protobuf gets the latter, so a decoded notification
// is the same text on Hermes and on JSC; the API transport and JWT callers keep
// the former. See the note on decodeUtf8 for why they are not one function.
import { configureTextEncoding } from '@bufbuild/protobuf/wire';

type TextDecoderOptions = {fatal?: boolean};
type DecodeOptions = {stream?: boolean};

/** What an unencodable byte or an unpaired surrogate becomes, per the spec. */
const REPLACEMENT = '\uFFFD';

/**
 * Decode UTF-8, replacing every ill-formed byte with one U+FFFD, or throwing
 * if `fatal`.
 *
 * Deliberately per-byte: when a multi-byte sequence is cut short, this emits
 * one U+FFFD per byte of it where the spec — and every runtime's native
 * TextDecoder — emit one for the whole maximal subpart. `[e6 b1]` decodes to
 * two U+FFFD here and one natively.
 *
 * That is the contract of this function, not an oversight, and it is not the
 * one the protocol speaks: this decoder feeds API JSON and JWT payloads
 * (src/api/transport.ts, src/api/jwtClaims.ts), where a U+FFFD is followed by
 * `JSON.parse` failing on a body either way, so the count is never observable
 * and the per-byte form is cheaper. Anything that has to agree with the other
 * platform — a protobuf string, which carries user-visible text — decodes
 * through {@link decodeUtf8MaximalSubpart} instead. Do not "unify" the two:
 * a decoded push payload must be byte-identical on Hermes and on JSC, and the
 * token callers must keep seeing what they have always seen. Both behaviours
 * are pinned by tests in __tests__/textEncoding.test.ts.
 */
export function decodeUtf8(bytes: Uint8Array, fatal = false): string {
  const out: string[] = [];
  let i = 0;
  while (i < bytes.length) {
    const first = bytes[i];
    if (first === undefined) {
      break;
    }
    let cp: number;
    let length: number;
    if (first < 0x80) {
      cp = first;
      length = 1;
    } else if (first < 0xc2) {
      if (fatal) {
        throw new TypeError('The encoded data was not valid for encoding utf-8');
      }
      out.push(REPLACEMENT);
      i++;
      continue;
    } else if (first < 0xe0) {
      cp = first & 0x1f;
      length = 2;
    } else if (first < 0xf0) {
      cp = first & 0x0f;
      length = 3;
    } else if (first < 0xf8) {
      cp = first & 0x07;
      length = 4;
    } else {
      if (fatal) {
        throw new TypeError('The encoded data was not valid for encoding utf-8');
      }
      out.push(REPLACEMENT);
      i++;
      continue;
    }
    if (i + length > bytes.length) {
      if (fatal) {
        throw new TypeError('The encoded data was not valid for encoding utf-8');
      }
      out.push(REPLACEMENT);
      i++;
      continue;
    }
    let valid = true;
    for (let j = 1; j < length; j++) {
      const b = bytes[i + j];
      if (b === undefined || (b & 0xc0) !== 0x80) {
        valid = false;
        break;
      }
      cp = (cp << 6) | (b & 0x3f);
    }
    if (
      !valid ||
      (length === 2 && cp < 0x80) ||
      (length === 3 && cp < 0x800) ||
      (length === 4 && cp < 0x10000) ||
      cp > 0x10ffff ||
      (cp >= 0xd800 && cp <= 0xdfff)
    ) {
      if (fatal) {
        throw new TypeError('The encoded data was not valid for encoding utf-8');
      }
      out.push(REPLACEMENT);
      i++;
      continue;
    }
    out.push(String.fromCodePoint(cp));
    i += length;
  }
  return out.join('');
}

/**
 * Decode UTF-8 the way the Text Encoding API does: one U+FFFD per *maximal
 * subpart*, and `fatal` turns each of those into a throw instead.
 *
 * This is the decoder for anything whose output has to match another engine —
 * every protobuf string, i.e. every push notification. {@link decodeUtf8} is
 * the same decoder with a weaker rule and a different audience; see the note
 * there for why the two are kept apart.
 *
 * "Maximal subpart" is the Unicode/Encoding-Standard term for a byte prefix
 * that is still a possible start of a well-formed sequence. Concretely, and
 * this is where the two decoders part company:
 *
 *   - a truncated sequence is ONE U+FFFD for all of its bytes, not one per
 *     byte: `[e6 b1]` and `[e6 b1 28]` are both a single U+FFFD followed by
 *     `(`, because `[e6 b1]` is a valid prefix of U+6C49 and must not be
 *     re-examined once the next byte rules it out;
 *   - the byte that breaks the sequence is NOT consumed: `[c3 28]` is a
 *     U+FFFD for `[c3]` and then a perfectly good `(`;
 *   - the first byte of a sequence narrows the range the continuation bytes
 *     may occupy, which is how overlong forms and surrogates are caught —
 *     `[ed a0 80]` is three U+FFFD (one for `[ed]`, one per stray
 *     continuation byte) and `[f4 90 80 80]` four, rather than one for the
 *     whole run.
 */
export function decodeUtf8MaximalSubpart(bytes: Uint8Array, fatal = false): string {
  const out: string[] = [];
  let i = 0;
  while (i < bytes.length) {
    const first = bytes[i];
    if (first === undefined) {
      break;
    }
    if (first < 0x80) {
      out.push(String.fromCodePoint(first));
      i++;
      continue;
    }
    let cp: number;
    let length: number;
    // The window a continuation byte has to fall in. Narrowed for the first
    // bytes that could otherwise admit an overlong form or a surrogate, and
    // reset to the full 0x80..0xbf once a continuation byte is accepted.
    let lower = 0x80;
    let upper = 0xbf;
    if (first >= 0xc2 && first <= 0xdf) {
      cp = first & 0x1f;
      length = 2;
    } else if (first >= 0xe0 && first <= 0xef) {
      if (first === 0xe0) {
        lower = 0xa0; // 0xe0 0x80.. would be overlong
      }
      if (first === 0xed) {
        upper = 0x9f; // 0xed 0xa0.. would be a surrogate
      }
      cp = first & 0x0f;
      length = 3;
    } else if (first >= 0xf0 && first <= 0xf4) {
      if (first === 0xf0) {
        lower = 0x90; // 0xf0 0x80.. would be overlong
      }
      if (first === 0xf4) {
        upper = 0x8f; // 0xf4 0x90.. would be above U+10FFFF
      }
      cp = first & 0x07;
      length = 4;
    } else {
      // 0x80..0xbf can never continue a sequence (there is no sequence to
      // continue), 0xc0/0xc1 could only ever start an overlong form, and
      // 0xf5..0xff is above the last code point. One byte, one U+FFFD.
      if (fatal) {
        throw new TypeError('The encoded data was not valid for encoding utf-8');
      }
      out.push(REPLACEMENT);
      i++;
      continue;
    }
    // Walk the continuation bytes. `subpart` counts the bytes that are part of
    // the maximal subpart, so the byte that ends it — whether a bad
    // continuation or the end of the input — is left for the next iteration.
    let subpart = 1;
    let seen = 1;
    for (; seen < length; seen++) {
      const b = i + seen < bytes.length ? bytes[i + seen] : undefined;
      if (b === undefined || b < lower || b > upper) {
        break;
      }
      cp = (cp << 6) | (b & 0x3f);
      subpart++;
      lower = 0x80;
      upper = 0xbf;
    }
    if (seen === length) {
      out.push(String.fromCodePoint(cp));
      i += length;
      continue;
    }
    if (fatal) {
      throw new TypeError('The encoded data was not valid for encoding utf-8');
    }
    out.push(REPLACEMENT);
    i += subpart;
  }
  return out.join('');
}

/**
 * Minimal stand-in for the WHATWG `TextDecoder`, for Hermes.
 *
 * WHATWG semantics only: no streaming, no `ignoreBOM`, no encodings other
 * than UTF-8. It exists so code paths that construct the global — including
 * protobuf-es's own lazy codec — keep working.
 */
export class HermesTextDecoder {
  private fatal: boolean;

  constructor(_encoding?: string, options?: TextDecoderOptions) {
    this.fatal = options?.fatal ?? false;
  }

  decode(input?: Uint8Array | ArrayBuffer | null, _options?: DecodeOptions): string {
    if (input == null) {
      return '';
    }
    const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
    // Maximal-subpart, not per-byte: this class is the TextDecoder, so
    // anything that constructs the global on Hermes — app code, a library
    // decoding a response body — has to get the text it would get on JSC.
    // decodeUtf8 stays per-byte for its own callers; see the note on it.
    const text = decodeUtf8MaximalSubpart(bytes, this.fatal);
    // A TextDecoder consumes a leading BOM by default; `ignoreBOM: true` is
    // what keeps it, and this polyfill does not implement that option. Only the
    // global class does this — decodeUtf8 itself stays byte-faithful, because
    // its other callers have always seen the BOM as a character.
    return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  }
}

function isHighSurrogate(unit: number): boolean {
  // NaN & 0xfc00 === 0, so an out-of-range charCodeAt() fails this correctly.
  return (unit & 0xfc00) === 0xd800;
}

function isLowSurrogate(unit: number): boolean {
  return (unit & 0xfc00) === 0xdc00;
}

/**
 * Replace unpaired surrogates with U+FFFD, the way `TextEncoder` does.
 *
 * Returns the input unchanged (by identity, no copy) when there are none, so
 * the common case costs one scan and no allocation.
 */
function withLoneSurrogatesReplaced(text: string): string {
  let out = '';
  let copiedUpTo = 0;
  for (let i = 0; i < text.length; i++) {
    const unit = text.charCodeAt(i);
    if (isHighSurrogate(unit) && isLowSurrogate(text.charCodeAt(i + 1))) {
      // A valid pair; encodeURIComponent emits it as one code point.
      i++;
      continue;
    }
    if (isHighSurrogate(unit) || isLowSurrogate(unit)) {
      out += text.slice(copiedUpTo, i) + REPLACEMENT;
      copiedUpTo = i + 1;
    }
  }
  return copiedUpTo === 0 ? text : out + text.slice(copiedUpTo);
}

/**
 * UTF-8 encoder. `encodeURIComponent()` already produces UTF-8, escaping every
 * byte above 0x7f as "%XX"; ASCII characters pass through unchanged.
 *
 * Unpaired surrogates become U+FFFD rather than throwing, which is what the
 * `TextEncoder` this replaces does — a lone surrogate has no UTF-8 encoding,
 * and the spec's answer is the replacement character. The native protobuf-es
 * path agrees, so the two runtimes agree. `checkUtf8` is the strict question
 * and is what protobuf-es asks when it needs one.
 */
export function encodeUtf8(text: string) {
  const encoded = encodeURIComponent(withLoneSurrogatesReplaced(text));
  const bytes = new Uint8Array(encoded.length);
  let n = 0;
  for (let i = 0; i < encoded.length; i++) {
    const code = encoded.charCodeAt(i);
    if (code === 0x25 /* % */) {
      // An escape stands for one output byte; skip its two hex digits.
      bytes[n++] = parseInt(encoded.substring(i + 1, i + 3), 16);
      i += 2;
    } else {
      bytes[n++] = code;
    }
  }
  return bytes.subarray(0, n);
}

/** True when `text` is encodable as UTF-8 (i.e. has no lone surrogates). */
export function checkUtf8(text: string): boolean {
  // encodeUtf8 replaces unpaired surrogates, so "nothing was replaced" is the
  // validity test — the same answer encodeURIComponent used to give by
  // throwing.
  return withLoneSurrogatesReplaced(text) === text;
}

/** Minimal stand-in for the WHATWG `TextEncoder`, for Hermes. */
export class HermesTextEncoder {
  encode(input = '') {
    return encodeUtf8(input);
  }
}

const globals = globalThis as Record<string, unknown>;
const missingDecoder = globals.TextDecoder === undefined;
const missingEncoder = globals.TextEncoder === undefined;

/**
 * True when this module had to fill a gap: it installed a missing global or
 * took over protobuf-es's codec. False on any runtime that already ships
 * `TextEncoder` and `TextDecoder` (JSC, Node, V8, recent Hermes), where the
 * native implementations are left in place.
 */
export const textEncodingIsPolyfilled: boolean = missingDecoder || missingEncoder;

// Fill only the globals the runtime is actually missing.
if (missingDecoder) {
  globals.TextDecoder = HermesTextDecoder;
}
if (missingEncoder) {
  globals.TextEncoder = HermesTextEncoder;
}

// Hand protobuf-es the implementations directly rather than letting it build
// its codec out of the globals above: it does so lazily and unconditionally,
// and on Hermes at least one of the two is missing, so it would throw on the
// first string field. This runs only in that case — where a global is missing,
// there is nothing native to preserve, and the SDK is the only source of a
// codec. Everywhere else protobuf-es keeps its own native-backed one.
//
// Note which decode function is handed over: not decodeUtf8. This is the codec
// every protobuf string in the process decodes through — push notification
// titles and bodies included — so it has to carry the spec's maximal-subpart
// rule. The per-byte decoder would make a payload's text depend on whether the
// device happens to run Hermes or JSC, which is not a difference this wire
// protocol is allowed to have. decodeUtf8 stays the decoder for the API
// transport and JWT callers, which are not compared across engines.
if (textEncodingIsPolyfilled) {
  configureTextEncoding({ encodeUtf8, decodeUtf8: decodeUtf8MaximalSubpart, checkUtf8 });
}

export {};
