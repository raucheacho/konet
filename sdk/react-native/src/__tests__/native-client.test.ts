import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { KonetNativeClient, createNativeClient } from "../native-client.js";
import type { AppStateLike, AppStateSubscription } from "../app-state.js";

type WireFrame = [string | null, string | null, string, string, unknown];

class MockWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;

  static instances: MockWebSocket[] = [];

  static last(): MockWebSocket {
    const socket = MockWebSocket.instances[MockWebSocket.instances.length - 1];
    if (!socket) throw new Error("no socket was opened");
    return socket;
  }

  readyState: number = MockWebSocket.CONNECTING;
  sent: string[] = [];

  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: string }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;

  constructor(readonly url: string) {
    MockWebSocket.instances.push(this);
  }

  send(data: string): void {
    this.sent.push(data);
  }

  close(): void {
    if (this.readyState === MockWebSocket.CLOSED) return;
    this.readyState = MockWebSocket.CLOSED;
    this.onclose?.();
  }

  open(): void {
    this.readyState = MockWebSocket.OPEN;
    this.onopen?.();
  }

  /** The connection is gone but nothing tells us — what a resumed app sees. */
  goSilent(): void {
    this.onmessage = null;
  }

  framesOf(event: string): WireFrame[] {
    return this.sent
      .map((raw) => JSON.parse(raw) as WireFrame)
      .filter((f) => f[3] === event);
  }
}

/** Stands in for React Native's AppState. */
class FakeAppState implements AppStateLike {
  currentState: string | null = "active";
  listeners: Array<(state: string) => void> = [];
  removeCalls = 0;

  addEventListener(_type: "change", listener: (state: string) => void): AppStateSubscription {
    this.listeners.push(listener);
    return {
      remove: () => {
        this.removeCalls++;
        this.listeners = this.listeners.filter((l) => l !== listener);
      },
    };
  }

  emit(state: string): void {
    this.currentState = state;
    for (const listener of [...this.listeners]) listener(state);
  }
}

let appState: FakeAppState;

beforeEach(() => {
  vi.useFakeTimers();
  MockWebSocket.instances = [];
  appState = new FakeAppState();
  (globalThis as unknown as { WebSocket: unknown }).WebSocket = MockWebSocket;
});

afterEach(() => {
  vi.useRealTimers();
});

function connect() {
  const client = createNativeClient("ws://localhost:4000/socket", {
    token: "kt_test",
    appState,
  });
  const socket = MockWebSocket.last();
  socket.open();
  return { client, socket };
}

describe("app lifecycle", () => {
  it("subscribes to AppState on connect", () => {
    connect();
    expect(appState.listeners).toHaveLength(1);
  });

  it("probes the connection when the app returns to the foreground", () => {
    const { socket } = connect();

    expect(socket.framesOf("heartbeat")).toHaveLength(0);

    appState.emit("background");
    appState.emit("active");

    expect(
      socket.framesOf("heartbeat"),
      "foregrounding must verify the socket instead of trusting it"
    ).toHaveLength(1);
  });

  it("ignores transitions that are not a return to the foreground", () => {
    const { socket } = connect();

    appState.emit("background");
    appState.emit("inactive");

    expect(socket.framesOf("heartbeat")).toHaveLength(0);
  });

  it("reconnects and re-joins when the socket died while suspended", async () => {
    const { client, socket } = connect();

    const channel = client.channel("room:team-1:ptt");
    const joined = channel.subscribe();
    const join = socket.framesOf("phx_join")[0];
    socket.onmessage?.({
      data: JSON.stringify([join[0], join[1], join[2], "phx_reply", { status: "ok", response: {} }]),
    });
    await joined;

    // Backgrounded: the server timed the socket out, but this process was
    // frozen and never saw a close event.
    socket.goSilent();
    appState.emit("background");
    appState.emit("active");

    // The foreground probe goes unanswered, so the client gives up on the
    // socket and reconnects.
    await vi.advanceTimersByTimeAsync(10_000); // probe deadline
    await vi.advanceTimersByTimeAsync(1_000); // reconnect backoff

    const socket2 = MockWebSocket.last();
    expect(socket2).not.toBe(socket);

    socket2.open();
    expect(socket2.framesOf("phx_join")[0]?.[2]).toBe("room:team-1:ptt");

    client.disconnect();
  });

  it("removes the AppState listener on disconnect", () => {
    const { client } = connect();

    client.disconnect();

    expect(appState.removeCalls).toBe(1);
    expect(appState.listeners).toHaveLength(0);
  });

  it("does not probe after an explicit disconnect", () => {
    const { client, socket } = connect();
    client.disconnect();

    appState.emit("active");

    expect(socket.framesOf("heartbeat")).toHaveLength(0);
  });
});

describe("without React Native", () => {
  it("works as a plain client when AppState is unavailable", () => {
    const client = new KonetNativeClient("ws://localhost:4000/socket", {
      token: "kt_test",
      appState: null,
    });

    expect(() => client.connect()).not.toThrow();
    MockWebSocket.last().open();

    client.disconnect();
  });
});
