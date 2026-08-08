import { Channel } from "./channel.js";
import { BROADCAST, decodeServerFrame, encodePush, PUSH } from "./binary.js";

export interface KonetClientOptions {
  token: string;
  heartbeatIntervalMs?: number;
  reconnectDelayMs?: number;
  maxReconnectAttempts?: number;
  /**
   * How long to wait for a heartbeat reply before declaring the socket dead
   * and reconnecting. Keep it below the server's socket timeout (45s).
   */
  heartbeatTimeoutMs?: number;
}

type ConnectionState = "disconnected" | "connecting" | "connected" | "closing";

// Phoenix Channels v2 wire format: [join_ref, ref, topic, event, payload]
type PhxFrame = [string | null, string | null, string, string, unknown];

export class KonetClient {
  private url: string;
  private opts: Required<KonetClientOptions>;
  private ws: WebSocket | null = null;
  private state: ConnectionState = "disconnected";
  private channels: Map<string, Channel> = new Map();
  private refCounter = 0;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private heartbeatDeadline: ReturnType<typeof setTimeout> | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private reconnectAttempts = 0;
  private sendBuffer: PhxFrame[] = [];
  private pendingHeartbeatRef: string | null = null;
  private lastTickAt = 0;
  private closedByUser = false;

  constructor(url: string, options: KonetClientOptions) {
    this.url = url;
    this.opts = {
      heartbeatIntervalMs: 30_000,
      reconnectDelayMs: 1_000,
      maxReconnectAttempts: 10,
      heartbeatTimeoutMs: 10_000,
      ...options,
    };
  }

  connect(): this {
    if (this.state !== "disconnected") return this;
    this.closedByUser = false;
    this.reconnectAttempts = 0;
    this.openSocket();
    return this;
  }

  disconnect(): void {
    this.closedByUser = true;
    this.state = "closing";
    this.clearTimers();
    this.sendBuffer = [];

    const ws = this.ws;
    this.ws = null;
    for (const ch of this.channels.values()) ch._socketClosed();

    ws?.close(1000, "client disconnect");
    this.state = "disconnected";
  }

  channel(topic: string): Channel {
    if (this.channels.has(topic)) {
      return this.channels.get(topic)!;
    }

    const ch = new Channel(
      topic,
      (msg) =>
        this.sendFrame([msg.joinRef, msg.ref, msg.topic, msg.event, msg.payload]),
      (joinRef, ref, chanTopic, event, data) =>
        this.sendBinary(joinRef, ref, chanTopic, event, data),
      () => String(++this.refCounter),
      () => this.ws?.readyState === WebSocket.OPEN
    );

    this.channels.set(topic, ch);
    return ch;
  }

  /** True while the socket is open and joins/sends can reach the server. */
  get connected(): boolean {
    return this.state === "connected" && this.ws?.readyState === WebSocket.OPEN;
  }

  /**
   * Verify the connection is really alive, right now.
   *
   * Call this whenever the host environment may have suspended this client —
   * React Native returning to the foreground, a browser tab waking up. A
   * suspended socket stays `OPEN` locally long after the server timed it out
   * at 45s, so the only reliable check is a round trip: probe with a heartbeat
   * and reconnect if the probe goes unanswered.
   *
   * Also revives a client that exhausted `maxReconnectAttempts` while
   * suspended — coming back to the foreground is a fresh chance to connect.
   */
  checkConnection(): void {
    if (this.closedByUser) return;

    if (this.state === "disconnected") {
      if (this.reconnectTimer === null) {
        this.reconnectAttempts = 0;
        this.openSocket();
      }
      return;
    }

    if (this.state !== "connected") return;

    if (this.ws?.readyState !== WebSocket.OPEN) {
      this.forceReconnect();
      return;
    }

    // A heartbeat we sent before being suspended was never answered: whatever
    // the local socket claims, nothing is listening on the other end.
    if (this.pendingHeartbeatRef !== null) {
      this.forceReconnect();
      return;
    }

    this.lastTickAt = Date.now();
    this.sendHeartbeat();
  }

  private openSocket(): void {
    this.state = "connecting";

    // Phoenix mounts the actual websocket transport at "<socket path>/websocket",
    // not at the socket path itself (e.g. "/socket" -> "/socket/websocket").
    const base = this.url.replace(/\/$/, "");
    const wsUrl = `${base}/websocket?token=${encodeURIComponent(this.opts.token)}&vsn=2.0.0`;
    const ws = new WebSocket(wsUrl);
    this.ws = ws;

    ws.onopen = () => {
      // A forced reconnect can supersede a socket before it finishes opening.
      if (this.ws !== ws) return;

      this.state = "connected";
      this.reconnectAttempts = 0;
      this.pendingHeartbeatRef = null;

      // The server knows nothing about the topics this client had joined on
      // the previous socket, so re-issue phx_join before anything else goes
      // out. Without this the client looks connected while every send lands
      // on a socket that has no such topic.
      for (const ch of this.channels.values()) ch._rejoin();

      this.startHeartbeat();
      this.flushSendBuffer();
    };

    // Binary frames arrive as ArrayBuffer rather than Blob, so they can be
    // read synchronously — a Blob would force an async round trip per frame,
    // fifty times a second, for nothing.
    ws.binaryType = "arraybuffer";

    ws.onmessage = (ev) =>
      typeof ev.data === "string"
        ? this.handleFrame(ev.data)
        : this.handleBinaryFrame(ev.data as ArrayBuffer);

    ws.onclose = () => {
      if (this.ws !== ws) return;
      this.ws = null;
      this.clearTimers();

      // Every server-side join died with the socket. Marking the channels
      // makes send() fail loudly instead of writing into a dead topic, and
      // tells the next onopen which channels to re-join.
      for (const ch of this.channels.values()) ch._socketClosed();

      // Buffered frames carry join refs from the socket that just died.
      this.sendBuffer = [];

      const wasClosing = this.closedByUser || this.state === "closing";
      this.state = "disconnected";
      if (!wasClosing) this.scheduleReconnect();
    };

    ws.onerror = () => {
      /* onclose fires next */
    };
  }

  private handleFrame(data: string): void {
    let frame: PhxFrame;
    try {
      frame = JSON.parse(data);
    } catch {
      return;
    }

    const [joinRef, ref, topic, event, payload] = frame;

    if (topic === "phoenix") {
      // The heartbeat reply is this client's only proof the server is still
      // there — it is the liveness signal, not noise to discard.
      if (event === "phx_reply" && ref !== null && ref === this.pendingHeartbeatRef) {
        this.pendingHeartbeatRef = null;
        this.clearHeartbeatDeadline();
      }
      return;
    }

    const ch = this.channels.get(topic);
    if (ch) {
      ch._receive({ joinRef, ref, topic, event, payload });
    }
  }

  private handleBinaryFrame(buffer: ArrayBuffer): void {
    const frame = decodeServerFrame(buffer);
    if (frame === null) return;

    // A binary reply means the server refused the frame; it is delivered on
    // the same path as a text reply so callers have one place to look.
    if (frame.kind !== BROADCAST && frame.kind !== PUSH) return;

    this.channels.get(frame.topic)?._receiveBinary(frame.event, frame.data);
  }

  /**
   * Binary frames are never buffered while the socket is down, unlike text.
   * Replaying audio recorded seconds ago into a live channel would be worse
   * than losing it — by the time it arrives, the moment has passed.
   */
  private sendBinary(
    joinRef: string,
    ref: string,
    topic: string,
    event: string,
    data: Uint8Array
  ): void {
    if (this.ws?.readyState !== WebSocket.OPEN) return;
    this.ws.send(encodePush(joinRef, ref, topic, event, data));
  }

  private sendFrame(frame: PhxFrame): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(frame));
    } else {
      // Socket isn't open yet (e.g. send() racing the initial connect) —
      // buffer and flush once connected instead of silently dropping the
      // frame. Joins deliberately never take this path: they are issued from
      // onopen so that first-connect and reconnect follow the same code.
      this.sendBuffer.push(frame);
    }
  }

  private flushSendBuffer(): void {
    const buffered = this.sendBuffer;
    this.sendBuffer = [];
    for (const frame of buffered) {
      this.sendFrame(frame);
    }
  }

  private startHeartbeat(): void {
    this.lastTickAt = Date.now();
    this.heartbeatTimer = setInterval(
      () => this.onHeartbeatTick(),
      this.opts.heartbeatIntervalMs
    );
  }

  private onHeartbeatTick(): void {
    const now = Date.now();
    const elapsed = now - this.lastTickAt;
    this.lastTickAt = now;

    // setInterval is a scheduler, not a clock. React Native suspends timers in
    // the background and browsers throttle them in inactive tabs, so a tick
    // can land minutes late — long after the server's 45s timeout dropped us.
    // Trust elapsed wall-clock time over the schedule we asked for.
    if (elapsed > this.opts.heartbeatIntervalMs * 2) {
      this.checkConnection();
      return;
    }

    this.sendHeartbeat();
  }

  private sendHeartbeat(): void {
    if (this.ws?.readyState !== WebSocket.OPEN) return;
    // One probe in flight at a time; its deadline owns the outcome.
    if (this.pendingHeartbeatRef !== null) return;

    const ref = String(++this.refCounter);
    this.pendingHeartbeatRef = ref;
    this.sendFrame([null, ref, "phoenix", "heartbeat", {}]);

    this.clearHeartbeatDeadline();
    this.heartbeatDeadline = setTimeout(() => {
      this.heartbeatDeadline = null;
      if (this.pendingHeartbeatRef !== null) this.forceReconnect();
    }, this.opts.heartbeatTimeoutMs);
  }

  /** Tear down a socket that is open locally but unreachable, and reconnect. */
  private forceReconnect(): void {
    const ws = this.ws;
    this.ws = null;
    this.clearTimers();

    for (const ch of this.channels.values()) ch._socketClosed();
    this.sendBuffer = [];
    this.state = "disconnected";

    // this.ws is already null, so the old socket's onclose bails on its guard
    // and cannot schedule a second reconnect.
    try {
      ws?.close(4000, "heartbeat timeout");
    } catch {
      /* already gone */
    }

    this.reconnectAttempts = 0;
    this.scheduleReconnect();
  }

  private scheduleReconnect(): void {
    if (this.reconnectAttempts >= this.opts.maxReconnectAttempts) return;

    const delay = Math.min(
      this.opts.reconnectDelayMs * Math.pow(2, this.reconnectAttempts),
      30_000
    );

    this.reconnectAttempts++;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.openSocket();
    }, delay);
  }

  private clearHeartbeatDeadline(): void {
    if (this.heartbeatDeadline) clearTimeout(this.heartbeatDeadline);
    this.heartbeatDeadline = null;
  }

  private clearTimers(): void {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.heartbeatTimer = null;
    this.reconnectTimer = null;
    this.pendingHeartbeatRef = null;
    this.clearHeartbeatDeadline();
  }
}
