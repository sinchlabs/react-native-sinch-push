type TextDecoderOptions = {fatal?: boolean};
type DecodeOptions = {stream?: boolean};

export function decodeUtf8(bytes: Uint8Array, fatal: boolean): string {
  const out: string[] = [];
  const REPLACEMENT = '\uFFFD';
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

class HermesTextDecoder {
  private fatal: boolean;

  constructor(_encoding?: string, options?: TextDecoderOptions) {
    this.fatal = options?.fatal ?? false;
  }

  decode(input?: Uint8Array | ArrayBuffer | null, _options?: DecodeOptions): string {
    if (input == null) {
      return '';
    }
    const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
    return decodeUtf8(bytes, this.fatal);
  }
}

if (globalThis.TextDecoder === undefined) {
  (globalThis as Record<string, unknown>).TextDecoder = HermesTextDecoder;
}

export {};
