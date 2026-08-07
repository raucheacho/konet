/**
 * Minimal WebSocket stand-in: enough surface for KonetClient, plus hooks to
 * drive the situations that matter (server replies, an abrupt network drop, a
 * socket that stays OPEN locally while nothing answers on the other end).
 */
export type WireFrame = [string | null, string | null, string, string, unknown];

export class MockWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;

  static instances: MockWebSocket[] = [];

  static reset(): void {
    MockWebSocket.instances = [];
  }

  static last(): MockWebSocket {
    const socket = MockWebSocket.instances[MockWebSocket.instances.length - 1];
    if (!socket) throw new Error("no socket was opened");
    return socket;
  }

  readonly url: string;
  readyState: number = MockWebSocket.CONNECTING;
  sent: string[] = [];
  closeCalls: Array<{ code?: number; reason?: string }> = [];

  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: string }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;

  constructor(url: string) {
    this.url = url;
    MockWebSocket.instances.push(this);
  }

  send(data: string): void {
    this.sent.push(data);
  }

  close(code?: number, reason?: string): void {
    this.closeCalls.push({ code, reason });
    if (this.readyState === MockWebSocket.CLOSED) return;
    this.readyState = MockWebSocket.CLOSED;
    this.onclose?.();
  }

  // --- test controls -------------------------------------------------------

  /** Complete the handshake. */
  open(): void {
    this.readyState = MockWebSocket.OPEN;
    this.onopen?.();
  }

  /** The network dies and the close event does reach us. */
  drop(): void {
    this.readyState = MockWebSocket.CLOSED;
    this.onclose?.();
  }

  /**
   * The connection is gone but nothing tells us — the socket keeps reporting
   * OPEN. This is what a suspended mobile app wakes up to.
   */
  goSilent(): void {
    this.onmessage = null;
  }

  serverSend(frame: WireFrame): void {
    this.onmessage?.({ data: JSON.stringify(frame) });
  }

  frames(): WireFrame[] {
    return this.sent.map((raw) => JSON.parse(raw) as WireFrame);
  }

  framesOf(event: string): WireFrame[] {
    return this.frames().filter((f) => f[3] === event);
  }

  lastFrameOf(event: string): WireFrame | undefined {
    const matching = this.framesOf(event);
    return matching[matching.length - 1];
  }
}

/** Reply to a channel join or send, the way Phoenix does. */
export function replyTo(
  socket: MockWebSocket,
  frame: WireFrame,
  status: "ok" | "error",
  response: unknown = {}
): void {
  socket.serverSend([frame[0], frame[1], frame[2], "phx_reply", { status, response }]);
}
