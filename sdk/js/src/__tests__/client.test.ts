import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { KonetClient, reconnectDelay } from "../client.js";
import type { ConnectionStatus } from "../client.js";
import type { KonetSendError } from "../channel.js";
import { MockWebSocket, replyTo, WireFrame } from "./mock-socket.js";

const TOPIC = "room:team-1:map";

beforeEach(() => {
  vi.useFakeTimers();
  MockWebSocket.reset();
  (globalThis as unknown as { WebSocket: unknown }).WebSocket = MockWebSocket;
});

afterEach(() => {
  vi.useRealTimers();
});

/** Connect, open the socket, and join a channel that the server accepts. */
async function connectAndJoin(topic = TOPIC) {
  const client = new KonetClient("ws://localhost:4000/socket", { token: "kt_test" });
  client.connect();

  const socket = MockWebSocket.last();
  const channel = client.channel(topic);
  const joined = channel.subscribe();

  socket.open();
  const join = socket.lastFrameOf("phx_join")!;
  replyTo(socket, join, "ok");
  await joined;

  return { client, socket, channel, join };
}

describe("join lifecycle", () => {
  it("issues the join once the socket opens, even if subscribe() ran first", async () => {
    const client = new KonetClient("ws://localhost:4000/socket", { token: "kt_test" });
    client.connect();

    const socket = MockWebSocket.last();
    const channel = client.channel(TOPIC);
    const joined = channel.subscribe();

    // Nothing can go out before the handshake completes.
    expect(socket.framesOf("phx_join")).toHaveLength(0);

    socket.open();
    const join = socket.lastFrameOf("phx_join");
    expect(join).toBeDefined();
    expect(join![2]).toBe(TOPIC);

    replyTo(socket, join!, "ok");
    await expect(joined).resolves.toBeUndefined();
  });

  it("rejects the subscribe promise when the server refuses the join", async () => {
    const client = new KonetClient("ws://localhost:4000/socket", { token: "kt_test" });
    client.connect();

    const socket = MockWebSocket.last();
    const joined = client.channel("room:forbidden").subscribe();
    socket.open();

    replyTo(socket, socket.lastFrameOf("phx_join")!, "error", { reason: "unauthorized" });
    await expect(joined).rejects.toThrow(/unauthorized/);
  });
});

// A1 — the regression this suite exists for.
describe("reconnect", () => {
  it("re-joins channels and delivers sends after a dropped connection", async () => {
    const { client, socket, channel, join } = await connectAndJoin();

    socket.drop();
    await vi.advanceTimersByTimeAsync(1_000); // first backoff step

    const socket2 = MockWebSocket.last();
    expect(socket2).not.toBe(socket);

    socket2.open();
    const rejoin = socket2.lastFrameOf("phx_join");
    expect(rejoin, "the channel must be re-joined on the new socket").toBeDefined();
    expect(rejoin![2]).toBe(TOPIC);
    expect(rejoin![1], "the join ref must be fresh").not.toBe(join[1]);

    replyTo(socket2, rejoin!, "ok");

    channel.send("pos", { lat: 48.85, lng: 2.35 });

    const broadcast = socket2.lastFrameOf("broadcast");
    expect(broadcast, "the send must reach the new socket").toBeDefined();
    expect(broadcast![0], "the send must carry the new join ref").toBe(rejoin![1]);
    expect(broadcast![4]).toEqual({ event: "pos", payload: { lat: 48.85, lng: 2.35 } });

    client.disconnect();
  });

  it("fails sends loudly while disconnected instead of writing into the void", async () => {
    const { channel, socket } = await connectAndJoin();

    socket.drop();

    expect(() => channel.send("pos", { lat: 1 })).toThrow(/not joined/);
  });

  it("does not re-join a channel that was explicitly left", async () => {
    const { client, socket, channel } = await connectAndJoin();

    channel.unsubscribe();
    socket.drop();
    await vi.advanceTimersByTimeAsync(1_000);

    const socket2 = MockWebSocket.last();
    socket2.open();

    expect(socket2.framesOf("phx_join")).toHaveLength(0);

    client.disconnect();
  });

  it("re-joins only the channels that are still wanted", async () => {
    const { client, socket } = await connectAndJoin();

    const other = client.channel("room:team-1:ptt");
    const otherJoined = other.subscribe();
    replyTo(socket, socket.lastFrameOf("phx_join")!, "ok");
    await otherJoined;

    other.unsubscribe();
    socket.drop();
    await vi.advanceTimersByTimeAsync(1_000);

    const socket2 = MockWebSocket.last();
    socket2.open();

    const topics = socket2.framesOf("phx_join").map((f) => f[2]);
    expect(topics).toEqual([TOPIC]);

    client.disconnect();
  });

  it("stays closed after disconnect()", async () => {
    const { client, socket } = await connectAndJoin();
    const socketCount = MockWebSocket.instances.length;

    client.disconnect();
    expect(socket.readyState).toBe(MockWebSocket.CLOSED);

    await vi.advanceTimersByTimeAsync(60_000);
    expect(MockWebSocket.instances).toHaveLength(socketCount);
  });
});

// A2 — a refused broadcast must be observable.
describe("send errors", () => {
  it("routes a rate_limited reply to the send callback and the channel", async () => {
    const { client, socket, channel } = await connectAndJoin();

    const seen: KonetSendError[] = [];
    channel.on("send_error", (e) => seen.push(e as KonetSendError));

    const onError = vi.fn();
    channel.send("audio", { seq: 1 }, onError);

    const sent = socket.lastFrameOf("broadcast")!;
    replyTo(socket, sent, "error", { reason: "rate_limited" });

    expect(onError).toHaveBeenCalledTimes(1);
    expect(onError.mock.calls[0][0]).toMatchObject({
      topic: TOPIC,
      event: "audio",
      payload: { seq: 1 },
      reason: "rate_limited",
    });
    expect(seen).toHaveLength(1);

    client.disconnect();
  });

  it("stops tracking a send that the server never refuses", async () => {
    const { client, socket, channel } = await connectAndJoin();

    const onError = vi.fn();
    channel.send("pos", { lat: 1 }, onError);
    const sent = socket.lastFrameOf("broadcast")!;

    // Konet stays silent on success; the tracker must not leak.
    await vi.advanceTimersByTimeAsync(11_000);
    replyTo(socket, sent, "error", { reason: "rate_limited" });

    expect(onError).not.toHaveBeenCalled();

    client.disconnect();
  });
});

// A3 — timers are not a clock.
describe("heartbeat", () => {
  it("pings on schedule and clears the probe when the server answers", async () => {
    const { client, socket } = await connectAndJoin();

    await vi.advanceTimersByTimeAsync(30_000);
    const beat = socket.lastFrameOf("heartbeat");
    expect(beat).toBeDefined();

    socket.serverSend([null, beat![1], "phoenix", "phx_reply", { status: "ok", response: {} }]);

    // The unanswered-probe deadline must not fire now that we got a reply.
    await vi.advanceTimersByTimeAsync(10_000);
    expect(MockWebSocket.last()).toBe(socket);

    client.disconnect();
  });

  it("reconnects when a probe goes unanswered", async () => {
    const { client, socket } = await connectAndJoin();
    socket.goSilent();

    await vi.advanceTimersByTimeAsync(30_000); // probe sent
    await vi.advanceTimersByTimeAsync(10_000); // deadline expires
    await vi.advanceTimersByTimeAsync(1_000); // backoff

    const socket2 = MockWebSocket.last();
    expect(socket2).not.toBe(socket);

    socket2.open();
    expect(socket2.lastFrameOf("phx_join")).toBeDefined();

    client.disconnect();
  });

  it("detects a suspended interval from elapsed wall-clock time", async () => {
    const { client, socket } = await connectAndJoin();
    socket.goSilent();

    // The host froze our timers for five minutes — well past the server's 45s
    // socket timeout — then let one tick through.
    vi.setSystemTime(Date.now() + 300_000);
    await vi.advanceTimersByTimeAsync(30_000);

    // The late tick probes instead of trusting the schedule.
    expect(socket.lastFrameOf("heartbeat")).toBeDefined();

    await vi.advanceTimersByTimeAsync(10_000); // probe deadline
    await vi.advanceTimersByTimeAsync(1_000); // backoff
    expect(MockWebSocket.last()).not.toBe(socket);

    client.disconnect();
  });
});

// The hook the React Native SDK builds on.
describe("checkConnection", () => {
  it("reconnects immediately when a probe was already outstanding", async () => {
    const { client, socket } = await connectAndJoin();
    socket.goSilent();

    await vi.advanceTimersByTimeAsync(30_000); // probe sent, unanswered
    client.checkConnection();

    expect(socket.readyState).toBe(MockWebSocket.CLOSED);

    await vi.advanceTimersByTimeAsync(1_000);
    expect(MockWebSocket.last()).not.toBe(socket);

    client.disconnect();
  });

  it("probes a connection that still looks healthy", async () => {
    const { client, socket } = await connectAndJoin();

    client.checkConnection();
    expect(socket.lastFrameOf("heartbeat")).toBeDefined();

    client.disconnect();
  });

  it("revives a client that exhausted its reconnect attempts", async () => {
    const client = new KonetClient("ws://localhost:4000/socket", {
      token: "kt_test",
      maxReconnectAttempts: 1,
    });
    client.connect();

    const socket = MockWebSocket.last();
    socket.open();
    socket.drop();

    await vi.advanceTimersByTimeAsync(1_000);
    MockWebSocket.last().drop(); // second attempt fails; budget exhausted
    await vi.advanceTimersByTimeAsync(60_000);

    const stalled = MockWebSocket.instances.length;
    client.checkConnection();

    expect(MockWebSocket.instances.length).toBe(stalled + 1);

    client.disconnect();
  });

  it("does nothing after an explicit disconnect", async () => {
    const { client } = await connectAndJoin();
    client.disconnect();

    const socketCount = MockWebSocket.instances.length;
    client.checkConnection();

    expect(MockWebSocket.instances).toHaveLength(socketCount);
  });
});

describe("presence", () => {
  it("resyncs presence after a reconnect", async () => {
    const { client, socket, channel } = await connectAndJoin();

    socket.serverSend([null, null, TOPIC, "presence_state", {
      alice: { metas: [{ online_at: 1 }] },
    }] as WireFrame);
    expect(channel.getPresence().list()).toHaveLength(1);

    socket.drop();
    await vi.advanceTimersByTimeAsync(1_000);

    const socket2 = MockWebSocket.last();
    socket2.open();
    replyTo(socket2, socket2.lastFrameOf("phx_join")!, "ok");

    socket2.serverSend([null, null, TOPIC, "presence_state", {
      bob: { metas: [{ online_at: 2 }] },
    }] as WireFrame);

    expect(channel.getPresence().list().map((e) => e.id)).toEqual(["bob"]);

    client.disconnect();
  });
});

describe("binary mode", () => {
  it("leaves the join payload empty by default and reads an old server as exclusive", async () => {
    const { channel, join } = await connectAndJoin();

    // Unchanged on the wire for every existing push-to-talk client.
    expect(join[4]).toEqual({});
    // A server older than the mode replies `{}`; it only ever did exclusive.
    expect(channel.binaryMode).toBe("exclusive");
  });

  it("asks for multiplex on every join, reconnects included", async () => {
    const client = new KonetClient("ws://localhost:4000/socket", { token: "kt_test" });
    client.connect();
    const socket = MockWebSocket.last();
    const channel = client.channel("room:call-1", { binaryMode: "multiplex" });
    const joined = channel.subscribe();

    socket.open();
    const join = socket.lastFrameOf("phx_join")!;
    expect(join[4]).toEqual({ binary_mode: "multiplex" });
    replyTo(socket, join, "ok", { binary_mode: "multiplex" });
    await joined;
    expect(channel.binaryMode).toBe("multiplex");

    // The server forgets a topic's mode once it empties, so a rejoin that
    // dropped the parameter would come back exclusive — or be refused.
    socket.drop();
    expect(channel.binaryMode).toBeNull();
    await vi.advanceTimersByTimeAsync(1_000);
    const socket2 = MockWebSocket.last();
    socket2.open();
    expect(socket2.lastFrameOf("phx_join")![4]).toEqual({ binary_mode: "multiplex" });

    client.disconnect();
  });

  it("surfaces a mode mismatch as a refused join", async () => {
    const client = new KonetClient("ws://localhost:4000/socket", { token: "kt_test" });
    client.connect();
    const socket = MockWebSocket.last();
    const joined = client.channel("room:walkie").subscribe();
    socket.open();

    replyTo(socket, socket.lastFrameOf("phx_join")!, "error", {
      reason: "binary_mode_mismatch",
      binary_mode: "multiplex",
    });
    await expect(joined).rejects.toThrow(/binary_mode_mismatch/);
  });

  it("hands a multiplex frame to its handler with the sender split off", async () => {
    const client = new KonetClient("ws://localhost:4000/socket", { token: "kt_test" });
    client.connect();
    const socket = MockWebSocket.last();
    const channel = client.channel("room:call-3", { binaryMode: "multiplex" });
    const joined = channel.subscribe();
    socket.open();
    replyTo(socket, socket.lastFrameOf("phx_join")!, "ok", { binary_mode: "multiplex" });
    await joined;

    const heard: Array<[number[], string | undefined]> = [];
    channel.on("a", (data, sender) => heard.push([Array.from(data as Uint8Array), sender]));

    const stamped = (id: string, ...data: number[]) => {
      const bytes = new TextEncoder().encode(id);
      return new Uint8Array([bytes.length, ...bytes, ...data]);
    };
    socket.serverBroadcastBinary("room:call-3", "a", stamped("alice", 1, 2));
    socket.serverBroadcastBinary("room:call-3", "a", stamped("bob", 1, 2));
    // Too short for its own prefix: dropped, not delivered half-parsed.
    socket.serverBroadcastBinary("room:call-3", "a", new Uint8Array([9]));

    expect(heard).toEqual([
      [[1, 2], "alice"],
      [[1, 2], "bob"],
    ]);
    client.disconnect();
  });

  it("leaves an exclusive frame untouched, with no sender", async () => {
    const { client, socket, channel } = await connectAndJoin();

    const heard: Array<[number[], string | undefined]> = [];
    channel.on("a", (data, sender) => heard.push([Array.from(data as Uint8Array), sender]));
    socket.serverBroadcastBinary(TOPIC, "a", new Uint8Array([5, 1, 2]));

    // The leading 5 is data here, not a length: exclusive frames have no prefix.
    expect(heard).toEqual([[[5, 1, 2], undefined]]);
    client.disconnect();
  });

  it("refuses to hand back an existing channel under a different mode", () => {
    const client = new KonetClient("ws://localhost:4000/socket", { token: "kt_test" });
    const channel = client.channel("room:call-2", { binaryMode: "multiplex" });

    expect(client.channel("room:call-2")).toBe(channel);
    expect(client.channel("room:call-2", { binaryMode: "multiplex" })).toBe(channel);
    expect(() => client.channel("room:call-2", { binaryMode: "exclusive" })).toThrow(/multiplex/);
  });
});

describe("reconnect backoff", () => {
  it("keeps half of each step fixed and jitters the other half", () => {
    // Without jitter every client dropped by a restart came back in lockstep.
    expect(reconnectDelay(1_000, 0, () => 0)).toBe(500);
    expect(reconnectDelay(1_000, 0, () => 1)).toBe(1_000);
    expect(reconnectDelay(1_000, 2, () => 0.5)).toBe(3_000);
  });

  it("never exceeds the 30 s ceiling", () => {
    expect(reconnectDelay(1_000, 20, () => 1)).toBe(30_000);
    expect(reconnectDelay(1_000, 20, () => 0)).toBe(15_000);
  });

  it("spreads clients that dropped at the same moment", () => {
    const delays = new Set(Array.from({ length: 20 }, () => reconnectDelay(1_000, 3)));
    expect(delays.size).toBeGreaterThan(1);
  });
});

describe("connection status", () => {
  it("reports each step, including giving up", async () => {
    const client = new KonetClient("ws://localhost:4000/socket", {
      token: "kt_test",
      maxReconnectAttempts: 1,
    });
    const seen: ConnectionStatus[] = [];
    client.onStatus((status) => seen.push(status));

    client.connect();
    MockWebSocket.last().open();
    MockWebSocket.last().drop();
    await vi.advanceTimersByTimeAsync(1_000);
    MockWebSocket.last().drop(); // the only retry fails too

    expect(seen.map((s) => s.state)).toEqual([
      "connecting",
      "connected",
      "reconnecting",
      "connecting",
      "failed",
    ]);
    const retry = seen[2] as Extract<ConnectionStatus, { state: "reconnecting" }>;
    expect(retry.attempt).toBe(1);
    expect(retry.delayMs).toBeGreaterThanOrEqual(500);
    expect(retry.delayMs).toBeLessThanOrEqual(1_000);
  });

  it("reports an explicit disconnect, once, and stops reporting when removed", async () => {
    const client = new KonetClient("ws://localhost:4000/socket", { token: "kt_test" });
    const seen: string[] = [];
    const off = client.onStatus((status) => seen.push(status.state));

    client.connect();
    MockWebSocket.last().open();
    client.disconnect();
    client.disconnect();
    expect(seen).toEqual(["connecting", "connected", "disconnected"]);

    off();
    client.connect();
    expect(seen).toHaveLength(3);
    client.disconnect();
  });

  it("does not let a failing handler break the connection", async () => {
    const client = new KonetClient("ws://localhost:4000/socket", { token: "kt_test" });
    client.onStatus(() => {
      throw new Error("ui bug");
    });

    client.connect();
    MockWebSocket.last().open();
    expect(client.connected).toBe(true);
    client.disconnect();
  });
});
