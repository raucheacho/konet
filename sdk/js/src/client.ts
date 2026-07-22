import { Channel } from "./channel.js";

export interface KonetClientOptions {
  token: string;
  heartbeatIntervalMs?: number;
  reconnectDelayMs?: number;
  maxReconnectAttempts?: number;
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
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private reconnectAttempts = 0;
  private sendBuffer: PhxFrame[] = [];

  constructor(url: string, options: KonetClientOptions) {
    this.url = url;
    this.opts = {
      heartbeatIntervalMs: 30_000,
      reconnectDelayMs: 1_000,
      maxReconnectAttempts: 10,
      ...options,
    };
  }

  connect(): this {
    if (this.state !== "disconnected") return this;
    this.openSocket();
    return this;
  }

  disconnect(): void {
    this.state = "closing";
    this.clearTimers();
    this.ws?.close(1000, "client disconnect");
    this.ws = null;
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
      () => String(++this.refCounter)
    );

    this.channels.set(topic, ch);
    return ch;
  }

  private openSocket(): void {
    this.state = "connecting";

    // Phoenix mounts the actual websocket transport at "<socket path>/websocket",
    // not at the socket path itself (e.g. "/socket" -> "/socket/websocket").
    const base = this.url.replace(/\/$/, "");
    const wsUrl = `${base}/websocket?token=${encodeURIComponent(this.opts.token)}&vsn=2.0.0`;
    this.ws = new WebSocket(wsUrl);

    this.ws.onopen = () => {
      this.state = "connected";
      this.reconnectAttempts = 0;
      this.startHeartbeat();
      this.flushSendBuffer();
    };

    this.ws.onmessage = (ev) => this.handleFrame(ev.data);

    this.ws.onclose = (ev) => {
      this.clearTimers();
      this.ws = null;

      if (this.state === "closing") {
        this.state = "disconnected";
        return;
      }

      this.state = "disconnected";
      this.scheduleReconnect();
    };

    this.ws.onerror = () => {
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

    if (topic === "phoenix" && event === "phx_reply") return;

    const ch = this.channels.get(topic);
    if (ch) {
      ch._receive({ joinRef, ref, topic, event, payload });
    }
  }

  private sendFrame(frame: PhxFrame): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(frame));
    } else {
      // Socket isn't open yet (e.g. subscribe() called right after createClient()) —
      // buffer and flush once connected instead of silently dropping the frame.
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
    this.heartbeatTimer = setInterval(() => {
      this.sendFrame([null, String(++this.refCounter), "phoenix", "heartbeat", {}]);
    }, this.opts.heartbeatIntervalMs);
  }

  private scheduleReconnect(): void {
    if (this.reconnectAttempts >= this.opts.maxReconnectAttempts) return;

    const delay = Math.min(
      this.opts.reconnectDelayMs * Math.pow(2, this.reconnectAttempts),
      30_000
    );

    this.reconnectAttempts++;
    this.reconnectTimer = setTimeout(() => this.openSocket(), delay);
  }

  private clearTimers(): void {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.heartbeatTimer = null;
    this.reconnectTimer = null;
  }
}
