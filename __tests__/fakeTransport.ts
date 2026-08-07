import type { Transport, UnaryResponse } from '@connectrpc/connect';
import type { DescMessage, DescMethodUnary, MessageInitShape } from '@bufbuild/protobuf';

type Handler = (methodName: string, request: any) => any;

export function fakeTransport(handler: Handler): Transport {
  return {
    unary: async <I extends DescMessage, O extends DescMessage>(
      method: DescMethodUnary<I, O>,
      _signal: AbortSignal | undefined,
      _timeoutMs: number | undefined,
      _header: Headers | undefined,
      message: MessageInitShape<I>,
    ): Promise<UnaryResponse<O>> => {
      const responseMessage = await handler(method.name, message);
      return {
        stream: false,
        header: new Headers(),
        trailer: new Headers(),
        message: responseMessage,
      } as unknown as UnaryResponse<O>;
    },
    stream: undefined as never,
  };
}
