/** How many lines were dropped because the queue was full. */
export let dropped: number;

/** Turns the library on. With no address or key it stays off and every call does nothing. */
export function start(options?: {
  version?: string;
  environment?: string;
  url?: string;
  key?: string;
  host?: string;
  insecure?: boolean;
  /** Send a deploy line with the version at start. On by default; the server records a deploy only when the version changes. */
  announceVersion?: boolean;
}): void;

export function beat(name: string, everySeconds?: number): void;

export function check(name: string, state: "ok" | "degraded" | "down", value?: number, note?: string): void;

export function metric(name: string, value: number, unit?: string): void;

export function log(
  level: "trace" | "debug" | "info" | "warn" | "error" | "fatal",
  msg: string,
  fields?: Record<string, unknown>,
): void;

/** A console that also sends each call through log. Pass a console to wrap it; the default is the global one. */
export function consoleLogger(target?: Console): Console;

/** Makes the global console send through log too. Returns a function that puts it back. */
export function patchConsole(): () => void;

/** Sends a stats document, for an app dokkit cannot reach. */
export function stats(document: Record<string, unknown>): void;

/** Reports a run of a job: its start, its progress, and how it ended. Returns what the work returns. */
export function job<T>(
  name: string,
  work: (run: { progress(done: number, total?: number): void }) => T | Promise<T>,
): Promise<T>;

/** Sends an error: its type and stack, never its message. */
export function capture(error: unknown, options?: { handled?: boolean; tags?: Record<string, unknown> }): void;

/** Also reports errors nothing caught. In Node the process ends after the report is sent, or after 3 seconds, unless another uncaughtException listener exists. */
export function catchUnhandled(): void;

/** Sends what is waiting. Runs by itself every two seconds. */
export function flush(): Promise<void>;
