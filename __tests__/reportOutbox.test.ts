// The report outbox flusher: TTL, batching, retry and the single-flight rule.
// The deps are fakes and `sleep` records instead of waiting, so no timer runs.

import { Code, ConnectError } from '@connectrpc/connect';
import {
  REPORT_BATCH_SIZE,
  REPORT_MAX_ATTEMPTS,
  REPORT_TTL_MS,
  ReportOutboxFlusher,
  reportBackoffMs,
  type ReportOutboxEntry,
} from '../src/api/reportOutbox';

const NOW = 1_800_000_000_000;

function entry(n: number, age = 0): ReportOutboxEntry {
  return { messageId: `m${n}`, subscriberId: `s${n}`, enqueuedAt: NOW - age };
}

function entries(count: number): ReportOutboxEntry[] {
  return Array.from({ length: count }, (_, i) => entry(i));
}

const ids = (list: ReadonlyArray<{ messageId: string }>) => list.map((e) => e.messageId);

function setup(initial: ReportOutboxEntry[], token: string | null = 'jwt-1') {
  let outbox = [...initial];
  let storedToken = token;
  const reported: Array<{ ids: string[]; token: string }> = [];
  const removed: string[][] = [];
  const sleeps: number[] = [];
  const state = {
    reportError: (_call: number): unknown => undefined,
    calls: 0,
  };
  const deps = {
    getOutbox: jest.fn(async () => [...outbox]),
    removeEntries: jest.fn(async (list: ReadonlyArray<{ messageId: string }>) => {
      removed.push(ids(list));
      const gone = new Set(ids(list));
      outbox = outbox.filter((e) => !gone.has(e.messageId));
    }),
    reportEvents: jest.fn(async (events: ReadonlyArray<{ messageId: string }>, jwt: string) => {
      state.calls += 1;
      const error = state.reportError(state.calls);
      reported.push({ ids: ids(events), token: jwt });
      if (error) throw error;
    }),
    currentToken: jest.fn(async () => storedToken),
    now: () => NOW,
    sleep: jest.fn(async (ms: number) => {
      sleeps.push(ms);
    }),
    random: () => 0.5,
  };
  return {
    flusher: new ReportOutboxFlusher(deps),
    deps,
    state,
    reported,
    removed,
    sleeps,
    remaining: () => ids(outbox),
    setToken: (t: string | null) => (storedToken = t),
  };
}

const connectError = (code: Code) => new ConnectError('failed', code);

describe('ReportOutboxFlusher', () => {
  beforeEach(() => {
    jest.spyOn(console, 'warn').mockImplementation(() => {});
  });
  afterEach(() => jest.restoreAllMocks());

  describe('what is sent', () => {
    it('makes no RPC for an empty outbox', async () => {
      const t = setup([]);

      await t.flusher.flush();

      expect(t.deps.reportEvents).not.toHaveBeenCalled();
      expect(t.deps.currentToken).not.toHaveBeenCalled();
    });

    it('removes an entry older than 72 hours natively and never sends it', async () => {
      const t = setup([entry(1, REPORT_TTL_MS + 1), entry(2, REPORT_TTL_MS - 1), entry(3)]);

      await t.flusher.flush();

      expect(t.removed[0]).toEqual(['m1']);
      expect(t.reported.flatMap((r) => r.ids)).toEqual(['m2', 'm3']);
    });

    it('sends nothing when every entry has expired', async () => {
      const t = setup([entry(1, REPORT_TTL_MS + 1)]);

      await t.flusher.flush();

      expect(t.remaining()).toEqual([]);
      expect(t.deps.reportEvents).not.toHaveBeenCalled();
    });

    it('splits 150 entries into a batch of 100 and a batch of 50, in order', async () => {
      const t = setup(entries(150));

      await t.flusher.flush();

      expect(t.reported.map((r) => r.ids.length)).toEqual([REPORT_BATCH_SIZE, 50]);
      expect(t.reported.flatMap((r) => r.ids)).toEqual(ids(entries(150)));
    });

    it('removes each batch natively once it is accepted', async () => {
      const t = setup(entries(150));

      await t.flusher.flush();

      expect(t.removed.map((r) => r.length)).toEqual([100, 50]);
      expect(t.remaining()).toEqual([]);
    });

    it('sends with the stored token', async () => {
      const t = setup(entries(2), 'jwt-7');

      await t.flusher.flush();

      expect(t.reported).toEqual([{ ids: ['m0', 'm1'], token: 'jwt-7' }]);
    });

    it('makes no RPC and keeps every entry without a token', async () => {
      const t = setup(entries(3), null);

      await t.flusher.flush();

      expect(t.deps.reportEvents).not.toHaveBeenCalled();
      expect(t.remaining()).toEqual(['m0', 'm1', 'm2']);
    });
  });

  describe('Unauthenticated', () => {
    it('retries the batch once with a newer stored token', async () => {
      const t = setup(entries(2), 'old');
      t.state.reportError = (call) => {
        if (call === 1) {
          t.setToken('new');
          return connectError(Code.Unauthenticated);
        }
        return undefined;
      };

      await t.flusher.flush();

      expect(t.reported.map((r) => r.token)).toEqual(['old', 'new']);
      expect(t.remaining()).toEqual([]);
      expect(t.sleeps).toEqual([]);
    });

    it('keeps the batch when the stored token is the one that was rejected', async () => {
      const t = setup(entries(2), 'old');
      t.state.reportError = () => connectError(Code.Unauthenticated);

      await t.flusher.flush();

      expect(t.deps.reportEvents).toHaveBeenCalledTimes(1);
      expect(t.remaining()).toEqual(['m0', 'm1']);
    });

    it('keeps the batch when the newer token is rejected too', async () => {
      const t = setup(entries(2), 'old');
      t.state.reportError = (call) => {
        if (call === 1) t.setToken('new');
        return connectError(Code.Unauthenticated);
      };

      await t.flusher.flush();

      expect(t.deps.reportEvents).toHaveBeenCalledTimes(2);
      expect(t.remaining()).toEqual(['m0', 'm1']);
    });

    it('keeps the batch when the token was removed meanwhile', async () => {
      const t = setup(entries(1), 'old');
      t.state.reportError = () => {
        t.setToken(null);
        return connectError(Code.Unauthenticated);
      };

      await t.flusher.flush();

      expect(t.deps.reportEvents).toHaveBeenCalledTimes(1);
      expect(t.remaining()).toEqual(['m0']);
    });

    it('keeps the later batches too once a batch stops on it', async () => {
      const t = setup(entries(150), 'old');
      t.state.reportError = () => connectError(Code.Unauthenticated);

      await t.flusher.flush();

      expect(t.remaining()).toHaveLength(150);
    });
  });

  describe.each([Code.InvalidArgument, Code.NotFound, Code.PermissionDenied])(
    'a permanent rejection (%s)',
    (code) => {
      it('removes the batch and carries on with the next', async () => {
        const t = setup(entries(150));
        t.state.reportError = (call) => (call === 1 ? connectError(code) : undefined);

        await t.flusher.flush();

        expect(t.deps.reportEvents).toHaveBeenCalledTimes(2);
        expect(t.removed.map((r) => r.length)).toEqual([100, 50]);
        expect(t.remaining()).toEqual([]);
        expect(t.sleeps).toEqual([]);
      });
    },
  );

  describe.each([
    ['Unavailable', () => connectError(Code.Unavailable)],
    ['DeadlineExceeded', () => connectError(Code.DeadlineExceeded)],
    ['Internal', () => connectError(Code.Internal)],
    ['a network failure', () => new TypeError('Network request failed')],
  ])('a transient failure (%s)', (_name, makeError) => {
    it('is retried after a backoff and the batch removed once it goes through', async () => {
      const t = setup(entries(2));
      t.state.reportError = (call) => (call <= 2 ? makeError() : undefined);

      await t.flusher.flush();

      expect(t.deps.reportEvents).toHaveBeenCalledTimes(3);
      expect(t.sleeps).toEqual([500, 1000]);
      expect(t.remaining()).toEqual([]);
    });

    it('stops after 5 failed attempts and keeps everything for the next trigger', async () => {
      const t = setup(entries(150));
      t.state.reportError = () => makeError();

      await t.flusher.flush();

      expect(t.deps.reportEvents).toHaveBeenCalledTimes(REPORT_MAX_ATTEMPTS);
      expect(t.sleeps).toEqual([500, 1000, 2000, 4000]);
      expect(t.remaining()).toHaveLength(150);
    });

    it('counts failures across batches', async () => {
      const t = setup(entries(150));
      t.state.reportError = (call) => (call === 1 || call >= 3 ? makeError() : undefined);

      await t.flusher.flush();

      expect(t.deps.reportEvents).toHaveBeenCalledTimes(REPORT_MAX_ATTEMPTS + 1);
      expect(t.remaining()).toHaveLength(50);
    });
  });

  describe('backoff', () => {
    it('is full jitter over min(30s, 1s · 2^attempt)', () => {
      expect([0, 1, 2, 3].map((a) => reportBackoffMs(a, () => 0.999))).toEqual([
        999, 1998, 3996, 7992,
      ]);
      expect(reportBackoffMs(0, () => 0)).toBe(0);
      expect(reportBackoffMs(4, () => 0.5)).toBe(8000);
    });

    it('is capped at 30 seconds however many attempts have failed', () => {
      expect(reportBackoffMs(10, () => 0.999999)).toBeLessThan(30_000);
      expect(reportBackoffMs(60, () => 0.5)).toBe(15_000);
    });
  });

  describe('single flight', () => {
    function gated(t: ReturnType<typeof setup>) {
      let release!: () => void;
      const gate = new Promise<void>((resolve) => (release = resolve));
      const original = t.deps.getOutbox.getMockImplementation()!;
      t.deps.getOutbox.mockImplementationOnce(async () => {
        await gate;
        return original();
      });
      return release;
    }

    it('does not start a second flush while one runs', async () => {
      const t = setup(entries(1));
      const release = gated(t);

      const first = t.flusher.flush();
      const second = t.flusher.flush();
      expect(t.deps.getOutbox).toHaveBeenCalledTimes(1);
      release();
      await Promise.all([first, second]);

      expect(t.deps.getOutbox).toHaveBeenCalledTimes(2);
    });

    it('runs exactly one follow-up however many flushes were requested meanwhile', async () => {
      const t = setup(entries(1));
      const release = gated(t);

      const all = [t.flusher.flush(), t.flusher.flush(), t.flusher.flush(), t.flusher.flush()];
      release();
      await Promise.all(all);

      expect(t.deps.getOutbox).toHaveBeenCalledTimes(2);
    });

    it('reads what was queued while the first run was busy in the follow-up', async () => {
      const t = setup(entries(1));
      const release = gated(t);

      const done = t.flusher.flush();
      const queuedLate = t.flusher.flush();
      release();
      await Promise.all([done, queuedLate]);

      expect(t.reported.map((r) => r.ids)).toEqual([['m0']]);
    });

    it('starts a fresh run once the previous one has ended', async () => {
      const t = setup([]);

      await t.flusher.flush();
      await t.flusher.flush();

      expect(t.deps.getOutbox).toHaveBeenCalledTimes(2);
    });
  });

  describe('native failures', () => {
    it('never rejects when reading the outbox fails, and the next flush still runs', async () => {
      const t = setup(entries(1));
      t.deps.getOutbox.mockRejectedValueOnce(new Error('bridge down'));

      await expect(t.flusher.flush()).resolves.toBeUndefined();
      await t.flusher.flush();

      expect(t.reported).toHaveLength(1);
      expect(console.warn).toHaveBeenCalledWith(
        '[sinch] flushing the report outbox failed',
        expect.any(Error),
      );
    });

    it('never rejects when removing entries fails', async () => {
      const t = setup(entries(1));
      t.deps.removeEntries.mockRejectedValueOnce(new Error('bridge down'));

      await expect(t.flusher.flush()).resolves.toBeUndefined();
    });
  });
});
