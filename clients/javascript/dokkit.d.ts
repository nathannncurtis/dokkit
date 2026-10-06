/** How many lines were dropped because the queue was full. */
export let dropped: number;

/** Turns the library on. With no address or key it stays off and every call does nothing. */
export function start(options?: {
  version?: string;
  environment?: string;
  url?: string;
  key?: string;
  host?: string;
}): void;

export function beat(name: string, everySeconds?: number): void;

export function check(name: string, state: "ok" | "degraded" | "down", value?: number, note?: string): void;

export function metric(name: string, value: number, unit?: string): void;

export function log(
  level: "trace" | "debug" | "info" | "warn" | "error" | "fatal",
  msg: string,
  fields?: Record<string, unknown>,
): void;

/** Sends a stats document, for an app dokkit cannot reach. */
export function stats(document: Record<string, unknown>): void;

/** Reports a run of a job: its start, its progress, and how it ended. Returns what the work returns. */
export function job<T>(
  name: string,
  work: (run: { progress(done: number, total?: number): void }) => T | Promise<T>,
): Promise<T>;

/** Sends an error: its type and stack, never its message. */
export function capture(error: unknown, options?: { handled?: boolean; tags?: Record<string, unknown> }): void;

/** Also reports errors nothing caught. */
export function catchUnhandled(): void;

/** Sends what is waiting. Runs by itself every two seconds. */
export function flush(): Promise<void>;
