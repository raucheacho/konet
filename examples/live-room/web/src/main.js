import { createClient } from "@raucheacho/konet-js";

// The room every participant (browsers + the Python agent) shares.
const ROOM = "room:live-room";
const EMOJIS = ["🎉", "❤️", "🔥", "👍", "😂", "🚀", "👀", "✨"];

// ---- Local identity -----------------------------------------------------
// Presence metadata is fixed server-side (online_at/room/role), so a client's
// display name, colour and cursor position travel inside broadcast payloads.
// Each client tags every message with a stable local id so it can ignore the
// echo of its own broadcasts (Phoenix delivers a broadcast back to its sender).
const me = {
  id: crypto.randomUUID(),
  name: randomName(),
  color: randomColor(),
};

// ---- DOM ----------------------------------------------------------------
const $ = (sel) => document.querySelector(sel);
const gate = $("#gate");
const stage = $("#stage");
const cursorsLayer = $("#cursors");
const reactionsLayer = $("#reactions");
const feed = $("#feed");

$("#name").value = me.name;
$("#token").value = localStorage.getItem("konet_token") || "";

// ---- Connect gate -------------------------------------------------------
$("#gate-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const url = $("#url").value.trim();
  const token = $("#token").value.trim();
  me.name = $("#name").value.trim() || me.name;

  if (!token) return showGateError("A token is required (your anon_key).");
  localStorage.setItem("konet_token", token);

  connect(url, token).catch((err) =>
    showGateError(err?.message || "Could not connect.")
  );
});

function showGateError(msg) {
  const el = $("#gate-error");
  el.textContent = msg;
  el.hidden = false;
}

// ---- Connect ------------------------------------------------------------
async function connect(url, token) {
  const client = createClient(url, { token });
  const channel = client.channel(ROOM);

  // subscribe() rejects if the socket errors or the join is refused.
  await channel.subscribe();

  // Reveal the app.
  gate.close();
  gate.hidden = true;
  for (const el of [$("#bar"), stage, $("#dock")]) el.hidden = false;
  $("#who").innerHTML = `You are <b style="color:${me.color}">${escapeHtml(me.name)}</b>`;

  wireStage(channel);
  wireReactions(channel);
  wireChat(channel);
  wirePresence(channel);
  wireIncoming(channel);
}

// ---- Cursors (broadcast) ------------------------------------------------
function wireStage(channel) {
  let last = 0;
  stage.addEventListener("mousemove", (e) => {
    const now = performance.now();
    if (now - last < 40) return; // ~25 msgs/s, well under the default rate limit
    last = now;
    const { x, y } = normalize(e);
    channel.send("cursor", { id: me.id, name: me.name, color: me.color, x, y });
  });
}

const cursors = new Map(); // id -> { el, tag, timer }

function renderCursor({ id, name, color, x, y }) {
  if (id === me.id) return; // ignore our own echo
  let c = cursors.get(id);
  if (!c) {
    const el = document.createElement("div");
    el.className = "cursor";
    el.innerHTML = `
      <svg width="20" height="20" viewBox="0 0 20 20" fill="${color}">
        <path d="M2 2l6 14 2.2-5.6L16 8z"/>
      </svg>
      <span class="tag" style="background:${color}"></span>`;
    el.querySelector(".tag").textContent = name;
    cursorsLayer.appendChild(el);
    c = { el, tag: el.querySelector(".tag"), timer: null };
    cursors.set(id, c);
  }
  c.tag.textContent = name;
  const px = x * stage.clientWidth;
  const py = y * stage.clientHeight;
  c.el.style.transform = `translate(${px}px, ${py}px)`;

  // Cursors self-expire: presence covers "who is online", this layer is a
  // best-effort visual that drops stale pointers after a few idle seconds.
  clearTimeout(c.timer);
  c.timer = setTimeout(() => {
    c.el.remove();
    cursors.delete(id);
  }, 5000);
}

// ---- Reactions (broadcast) ---------------------------------------------
function wireReactions(channel) {
  const dock = $("#emojis");
  for (const emoji of EMOJIS) {
    const b = document.createElement("button");
    b.textContent = emoji;
    b.addEventListener("click", () => {
      const x = 0.15 + Math.random() * 0.7;
      const y = 0.6 + Math.random() * 0.3;
      channel.send("reaction", { emoji, x, y });
      spawnReaction({ emoji, x, y }); // show ours immediately
    });
    dock.appendChild(b);
  }
}

function spawnReaction({ emoji, x, y }) {
  const el = document.createElement("div");
  el.className = "reaction";
  el.textContent = emoji;
  el.style.left = `${x * stage.clientWidth}px`;
  el.style.top = `${y * stage.clientHeight}px`;
  reactionsLayer.appendChild(el);
  setTimeout(() => el.remove(), 2000);
}

// ---- Chat (broadcast + history replay) ----------------------------------
function wireChat(channel) {
  const form = $("#chat-form");
  const input = $("#chat-input");
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    channel.send("chat", { id: me.id, name: me.name, color: me.color, text });
    input.value = "";
  });
}

function renderChat({ name, color, text }, opts = {}) {
  const el = document.createElement("div");
  el.className = "msg" + (opts.history ? " history" : "");
  el.innerHTML = `<b style="color:${color || "#fff"}">${escapeHtml(name || "?")}</b> ${escapeHtml(text || "")}`;
  feed.appendChild(el);
  feed.scrollTop = feed.scrollHeight;
}

// ---- Presence -----------------------------------------------------------
function wirePresence(channel) {
  channel.on("presence", (list) => {
    $("#count").textContent = list.length;
    $("#hint").style.opacity = list.length > 1 ? "0" : "0.9";
  });
}

// ---- Incoming broadcasts + history --------------------------------------
function wireIncoming(channel) {
  channel.on("cursor", renderCursor);
  channel.on("reaction", (p) => {
    if (p && typeof p.x === "number") spawnReaction(p);
  });
  channel.on("chat", (p) => renderChat(p));

  // Late joiners get the recent chat backlog in one push if the server has
  // KONET_HISTORY_LIMIT > 0. Older, "already happened" messages render dimmed.
  channel.on("konet:history", ({ messages }) => {
    for (const m of messages || []) {
      if (m.event === "chat") renderChat(m.payload, { history: true });
    }
  });
}

// ---- Helpers ------------------------------------------------------------
function normalize(e) {
  const r = stage.getBoundingClientRect();
  return {
    x: (e.clientX - r.left) / r.width,
    y: (e.clientY - r.top) / r.height,
  };
}

function randomColor() {
  const hues = [210, 145, 275, 20, 340, 50, 190, 110];
  const h = hues[Math.floor(Math.random() * hues.length)];
  return `hsl(${h} 75% 62%)`;
}

function randomName() {
  const a = ["Swift", "Bright", "Calm", "Bold", "Lucky", "Fuzzy", "Neon", "Cosmic"];
  const b = ["Otter", "Falcon", "Panda", "Comet", "Maple", "Tiger", "Robin", "Wolf"];
  return `${a[(Math.random() * a.length) | 0]} ${b[(Math.random() * b.length) | 0]}`;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
  );
}
