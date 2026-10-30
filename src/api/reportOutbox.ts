import { Code, ConnectError } from '@connectrpc/connect';

/** A provider push native queued as delivered-but-unreported. */
export interface ReportOutboxEntry {
  messageId: string;
  subscriberId: string;
  /** Epoch milliseconds the entry was queued at. */
  enqueuedAt: number;
}

export interface ReportOutboxDeps {
  getOutbox(): Promise<ReadonlyArray<ReportOutboxEntry>>;
  removeEntries(
    entries: ReadonlyArray<{ messageId: string; subscriberId: string }>,
  ): Promise<void>;
  reportEvents(
    events: ReadonlyArray<{ messageId: string; subscriberId: string }>,
    accessToken: string,
  ): Promise<void>;
  /** The stored device JWT; read again after `Unauthenticated` to pick up a newer one. */
  currentToken(): Promise<string | null>;
  now(): number;
  sleep(ms: number): Promise<void>;
  /** Uniform in [0, 1). */
  random(): number;
}

/** An entry older than this is dropped unsent. */
export const REPORT_TTL_MS = 72 * 60 * 60 * 1000;
export const REPORT_BATCH_SIZE = 100;
/** Failed attempts after which a flush gives up and leaves the rest for the next trigger. */
export const REPORT_MAX_ATTEMPTS = 5;
const BACKOFF_BASE_MS = 1000;
const BACKOFF_MAX_MS = 30_000;

/** Full jitter: `random(0, min(30s, 1s · 2^attempt))`, `attempt` counting failures from 0. */
export function reportBackoffMs(attempt: number, random: () => number): number {
  const ceiling = Math.min(BACKOFF_MAX_MS, BACKOFF_BASE_MS * 2 ** attempt);
  return Math.floor(random() * ceiling);
}

type Outcome = 'sent' | 'dropped' | 'retry' | 'unauthenticated';

function outcomeOf(e: unknown): Outcome {
  if (!(e instanceof ConnectError)) return 'retry';
  switch (e.code) {
    case Code.Unauthenticated:
      return 'unauthenticated';
    case Code.InvalidArgument:
    case Code.NotFound:
    case Code.PermissionDenied:
      return 'dropped';
    default:
      return 'retry';
  }
}

/**
 * Reports the native outbox as `DELIVERED`. At most one flush runs at a time; a
 * request made meanwhile costs exactly one more run after it. `flush` never
 * rejects: what it could not do stays in the outbox for the next trigger.
 */
export class ReportOutboxFlusher {
  private running: Promise<void> | null = null;
  private rerun = false;

  constructor(private readonly deps: ReportOutboxDeps) {}

  flush(): Promise<void> {
    if (this.running) {
      this.rerun = true;
      return this.running;
    }
    const run = this.drain().finally(() => {
      this.running = null;
    });
    this.running = run;
    return run;
  }

  private async drain(): Promise<void> {
    do {
      this.rerun = false;
      try {
        await this.flushOnce();
      } catch (e) {
        // eslint-disable-next-line no-console
        console.warn('[sinch] flushing the report outbox failed', e);
      }
    } while (this.rerun);
  }

  private async flushOnce(): Promise<void> {
    const { deps } = this;
    const entries = await deps.getOutbox();
    if (entries.length === 0) return;

    const cutoff = deps.now() - REPORT_TTL_MS;
    const expired = entries.filter((e) => e.enqueuedAt < cutoff);
    if (expired.length > 0) {
      await deps.removeEntries(expired);
    }
    const pending = entries.filter((e) => e.enqueuedAt >= cutoff);
    if (pending.length === 0) return;

    let token = await deps.currentToken();
    if (!token) return;

    let failures = 0;
    for (let i = 0; i < pending.length; i += REPORT_BATCH_SIZE) {
      const batch = pending.slice(i, i + REPORT_BATCH_SIZE);
      let refreshed = false;
      for (;;) {
        let outcome: Outcome = 'sent';
        try {
          await deps.reportEvents(batch, token);
        } catch (e) {
          outcome = outcomeOf(e);
          if (outcome === 'retry') {
            // eslint-disable-next-line no-console
            console.warn('[sinch] reporting delivered pushes failed', e);
          }
        }

        if (outcome === 'sent' || outcome === 'dropped') {
          await deps.removeEntries(batch);
          break;
        }
        if (outcome === 'unauthenticated') {
          const newer = refreshed ? null : await deps.currentToken();
          if (!newer || newer === token) return;
          token = newer;
          refreshed = true;
          continue;
        }
        failures += 1;
        if (failures >= REPORT_MAX_ATTEMPTS) return;
        await deps.sleep(reportBackoffMs(failures - 1, deps.random));
      }
    }
  }
}
