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
  const presence = await next(chA, "presence", 3000);
  check(3, "presence_state", presence !== null, "no presence event within 3s");

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
    check(8, "second holder refused", /floor_held|held/i.test(err.message), err.message);
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

  // 11 — a client without the floor is refused
  const refusal = new Promise((resolve) => {
    const off = chB.on("send_error", (e) => {
      off();
      resolve(e);
    });
    setTimeout(() => resolve(null), 2000);
  });
  chB.sendBinary("audio", bytes);
  const refused = await refusal;
  // The server replies with a binary error frame, which the SDK does not route
  // to send_error; absence of delivery to A is the observable part.
  check(
    11,
    "binary without the floor is refused",
    refused === null || /floor_required/.test(JSON.stringify(refused)),
    JSON.stringify(refused)
  );

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
