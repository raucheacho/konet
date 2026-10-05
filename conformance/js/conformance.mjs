// Conformance scenario — JavaScript SDK against a real konet-server.
// See ../README.md for the numbered steps.

import { createClient } from "../../sdk/js/dist/index.mjs";

const URL = process.env.KONET_URL ?? "ws://127.0.0.1:4009/socket";
const TOKEN = process.env.KONET_TOKEN;
// A second *identity*, not just a second socket: the floor is keyed on the
// user id from the "sub" claim, so two connections sharing a token count as one
// holder.
const TOKEN_B = process.env.KONET_TOKEN_B ?? TOKEN;
const ROOM = process.env.KONET_ROOM ?? `room:conf-js-${Date.now()}`;

if (!TOKEN) {
  console.error("KONET_TOKEN is required");
  process.exit(2);
}

// Node 20 has no global WebSocket; 22+ does. Polyfill only when needed so the
// SDK itself stays dependency-free.
if (typeof globalThis.WebSocket === "undefined") {
  const { WebSocket } = await import("ws");
  globalThis.WebSocket = WebSocket;
}

let failures = 0;

function pass(n, name) {
  console.log(`PASS ${n} ${name}`);
}

function fail(n, name, why) {
  failures++;
  console.log(`FAIL ${n} ${name}: ${why}`);
}

function check(n, name, condition, why = "condition was false") {
  condition ? pass(n, name) : fail(n, name, why);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Waits for `event` on `channel`, or resolves null after `ms`. */
function next(channel, event, ms = 3000) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      off();
      resolve(null);
    }, ms);
    const off = channel.on(event, (payload) => {
      clearTimeout(timer);
      off();
      resolve(payload);
    });
  });
}

async function main() {
  // 1 — connect
  const a = createClient(URL, { token: TOKEN });
  const b = createClient(URL, { token: TOKEN_B });
  const chA = a.channel(ROOM);
  const chB = b.channel(ROOM);

  // Registered before the join, not after: the server pushes presence_state
  // immediately behind the join reply, so a listener attached once subscribe()
  // has resolved is already too late. The Go and Python scenarios always did
  // this; leaving it out here passed locally and failed on CI.
  const presence = next(chA, "presence", 5000);

  try {
    await chA.subscribe();
    await chB.subscribe();
    pass(1, "connect");
    pass(2, "join");
  } catch (err) {
    fail(1, "connect+join", err.message);
    return;
  }

  // 3 — presence arrives unprompted after the join
  check(3, "presence_state", (await presence) !== null, "no presence event within 5s");

  // 4/5 — broadcast reaches the other client, and echoes to the sender
  const onB = next(chB, "conf:hello", 3000);
  const onA = next(chA, "conf:hello", 3000);
  chA.send("conf:hello", { n: 42 });

  const gotB = await onB;
  check(4, "broadcast reaches other client", gotB?.n === 42, `got ${JSON.stringify(gotB)}`);

  const gotA = await onA;
  check(5, "broadcast echoes to sender", gotA?.n === 42, `got ${JSON.stringify(gotA)}`);

  // 6/7 — floor acquisition is granted and announced to everyone
  const floorOnB = next(chB, "konet:floor", 3000);
  const floorOnA = next(chA, "konet:floor", 3000);

  let holder = null;
  try {
    holder = await chA.acquireFloor();
    check(6, "acquire floor", typeof holder === "string" && holder.length > 0, `holder=${holder}`);
  } catch (err) {
    fail(6, "acquire floor", err.message);
  }

  const annB = await floorOnB;
  const annA = await floorOnA;
  check(
    7,
    "floor announced to both",
    annB?.holder === holder && annA?.holder === holder,
    `A saw ${JSON.stringify(annA)}, B saw ${JSON.stringify(annB)}`
  );

  // 8 — the second client is refused, and told who holds it
  try {
    await chB.acquireFloor();
    fail(8, "second holder refused", "the second acquire succeeded");
  } catch (err) {
    check(
      8,
      "second holder refused",
      err.reason === "floor_held" && typeof err.holder === "string" && err.holder.length > 0,
      `reason=${err.reason} holder=${err.holder} message=${err.message}`
    );
  }

  // 9/10 — binary reaches B but must not echo to A
  const bytes = new Uint8Array([1, 2, 3, 250]);
  let binOnA = false;
  const offA = chA.on("audio", () => {
    binOnA = true;
  });
  const binOnB = next(chB, "audio", 3000);

  chA.sendBinary("audio", bytes);

  const received = await binOnB;
  const ok =
    received instanceof Uint8Array &&
    received.length === bytes.length &&
    [...received].every((v, i) => v === bytes[i]);
  check(9, "binary frame round-trips", ok, `got ${received && [...received]}`);

  await sleep(300);
  offA();
  check(10, "binary does not echo to sender", binOnA === false, "sender received its own audio");

  // 11/21 — a client without the floor is refused, is told so, and the
  // channel survives it
  const refusal = next(chB, "binary_error", 2000);
  chB.sendBinary("audio", bytes);
  const refused = await refusal;
  check(
    21,
    "a refused binary frame is reported",
    refused?.reason === "floor_required" && refused?.topic === ROOM,
    JSON.stringify(refused)
  );

  const surviving11 = next(chB, "conf:after-refusal", 3000);
  chA.send("conf:after-refusal", { ok: true });
  check(11, "channel survives a refused binary frame", (await surviving11)?.ok === true, "no traffic after the refusal");

  // 12 — release, then B can take it
  try {
    await chA.releaseFloor();
    const newHolder = await chB.acquireFloor();
    check(12, "floor is transferable", typeof newHolder === "string", `holder=${newHolder}`);
    await chB.releaseFloor();
  } catch (err) {
    fail(12, "floor is transferable", err.message);
  }

  // 12b — a second socket of the *same* user shares the floor rather than
  // being refused. This is what made step 8 pass spuriously when both clients
  // used one token.
  const sameUser = createClient(URL, { token: TOKEN });
  const chSame = sameUser.channel(ROOM);
  await chSame.subscribe();
  try {
    const held = await chA.acquireFloor();
    const alsoHeld = await chSame.acquireFloor();
    check(
      15,
      "the floor is per user, not per socket",
      held === alsoHeld,
      `A got ${held}, its other socket got ${alsoHeld}`
    );
    await chA.releaseFloor();
  } catch (err) {
    fail(15, "the floor is per user, not per socket", err.message);
  }
  sameUser.disconnect();

  // 13 — a late joiner receives the replay buffer
  const c = createClient(URL, { token: TOKEN });
  const chC = c.channel(ROOM);
  const historyPromise = next(chC, "konet:history", 4000);
  await chC.subscribe();
  const history = await historyPromise;

  const shapeOk =
    history &&
    Array.isArray(history.messages) &&
    history.messages.length > 0 &&
    history.messages.every(
      (m) => typeof m.event === "string" && "payload" in m && typeof m.timestamp === "string"
    );
  check(13, "konet:history replay", shapeOk, `got ${JSON.stringify(history)?.slice(0, 200)}`);

  // 14 — an unknown event is refused and the channel survives
  const surviving = next(chA, "conf:after", 3000);
  try {
    // send() only accepts the broadcast envelope, so reach for the raw push.
    chA.send("conf:after", { still: "here" });
    const after = await surviving;
    check(14, "channel survives bad input", after?.still === "here", JSON.stringify(after));
  } catch (err) {
    fail(14, "channel survives bad input", err.message);
  }

  // 16–19 — multiplex: both send at once, no floor, the mode is the topic's
  const CALL = `${ROOM}-call`;
  const callA = a.channel(CALL, { binaryMode: "multiplex" });
  const callB = b.channel(CALL, { binaryMode: "multiplex" });
  try {
    await callA.subscribe();
    await callB.subscribe();
    check(
      16,
      "multiplex join is confirmed",
      callA.binaryMode === "multiplex" && callB.binaryMode === "multiplex",
      `A=${callA.binaryMode} B=${callB.binaryMode}`
    );
  } catch (err) {
    fail(16, "multiplex join is confirmed", err.message);
  }

  const FRAMES = 10;
  const heard = { A: [], B: [] };
  const senders = { A: new Set(), B: new Set() };
  callA.on("voice", (data, sender) => {
    heard.A.push([...data]);
    senders.A.add(sender);
  });
  callB.on("voice", (data, sender) => {
    heard.B.push([...data]);
    senders.B.add(sender);
  });
  // Interleaved, with neither side taking anything first.
  for (let n = 0; n < FRAMES; n++) {
    callA.sendBinary("voice", new Uint8Array([0xa, n]));
    callB.sendBinary("voice", new Uint8Array([0xb, n]));
  }
  await sleep(500);
  const stream = (tag) => Array.from({ length: FRAMES }, (_, n) => [tag, n]);
  check(
    17,
    "two simultaneous streams both relayed",
    JSON.stringify(heard.A) === JSON.stringify(stream(0xb)) &&
      JSON.stringify(heard.B) === JSON.stringify(stream(0xa)),
    `A heard ${JSON.stringify(heard.A)}, B heard ${JSON.stringify(heard.B)}`
  );

  // 20 — each frame names its sender: one id per stream, and not the same one
  const [fromB] = senders.A;
  const [fromA] = senders.B;
  check(
    20,
    "multiplex frames carry their sender",
    senders.A.size === 1 && senders.B.size === 1 && !!fromA && !!fromB && fromA !== fromB,
    `A heard from ${[...senders.A]}, B heard from ${[...senders.B]}`
  );

  try {
    await callA.acquireFloor();
    fail(18, "multiplex has no floor", "acquire succeeded");
  } catch (err) {
    check(18, "multiplex has no floor", /floor_disabled/.test(err.message), err.message);
  }

  const walkie = createClient(URL, { token: TOKEN });
  try {
    await walkie.channel(CALL).subscribe();
    fail(19, "a joiner in the other mode is refused", "the exclusive join succeeded");
  } catch (err) {
    check(19, "a joiner in the other mode is refused", /binary_mode_mismatch/.test(err.message), err.message);
  }
  walkie.disconnect();

  // 22 — the multiplex topic is full at the server's ceiling (2 in this run)
  const third = createClient(URL, { token: TOKEN });
  try {
    await third.channel(CALL, { binaryMode: "multiplex" }).subscribe();
    fail(22, "a multiplex topic has a member ceiling", "the third member was accepted");
  } catch (err) {
    check(22, "a multiplex topic has a member ceiling", /topic_full/.test(err.message), err.message);
  }
  third.disconnect();

  a.disconnect();
  b.disconnect();
  c.disconnect();
}

main()
  .then(() => {
    console.log(failures === 0 ? "OK js" : `FAILED js (${failures})`);
    process.exit(failures === 0 ? 0 : 1);
  })
  .catch((err) => {
    console.error("unexpected error:", err);
    process.exit(1);
  });
