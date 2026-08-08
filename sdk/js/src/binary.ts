/**
 * Le format binaire de Phoenix Channels v2.
 *
 * Phoenix carries binary payloads in their own framing rather than base64
 * inside JSON — the difference matters for anything at a media rate, where a
 * third of overhead and a JSON parse per 20 ms frame is not free.
 *
 * Three shapes travel on the wire, distinguished by their first byte. The
 * field order below is transcribed from Phoenix's own serializer
 * (`Phoenix.Socket.V2.JSONSerializer`) and must stay in step with it; the
 * asymmetry — a push carries a ref, a broadcast carries neither ref nor
 * join_ref — is Phoenix's, not ours.
 *
 *   push      0 | join_ref_size | ref_size | topic_size | event_size | … | data
 *   reply     1 | join_ref_size | ref_size | topic_size | status_size | … | data
 *   broadcast 2 | topic_size | event_size | topic | event | data
 *
 * Every size is one byte, so each field is capped at 255 — checked on encode,
 * because a silently truncated topic would deliver audio to the wrong room.
 */

export const PUSH = 0;
export const REPLY = 1;
export const BROADCAST = 2;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export interface BinaryFrame {
  kind: typeof PUSH | typeof REPLY | typeof BROADCAST;
  topic: string;
  /** The event name, or the reply status ("ok" / "error"). */
  event: string;
  ref: string | null;
  joinRef: string | null;
  data: Uint8Array;
}

function sized(value: string, field: string): Uint8Array {
  const bytes = encoder.encode(value);
  if (bytes.length > 255) {
    throw new RangeError(`${field} dépasse 255 octets (${bytes.length})`);
  }
  return bytes;
}

/**
 * Builds a client push. `data` is copied into the frame, so the caller may
 * reuse its buffer immediately — which the audio path does, since its frame
 * buffer is reused every 20 ms.
 */
export function encodePush(
  joinRef: string,
  ref: string,
  topic: string,
  event: string,
  data: Uint8Array
): ArrayBuffer {
  const joinRefBytes = sized(joinRef, "join_ref");
  const refBytes = sized(ref, "ref");
  const topicBytes = sized(topic, "topic");
  const eventBytes = sized(event, "event");

  const header = 5;
  const total =
    header +
    joinRefBytes.length +
    refBytes.length +
    topicBytes.length +
    eventBytes.length +
    data.length;

  const buffer = new ArrayBuffer(total);
  const bytes = new Uint8Array(buffer);

  bytes[0] = PUSH;
  bytes[1] = joinRefBytes.length;
  bytes[2] = refBytes.length;
  bytes[3] = topicBytes.length;
  bytes[4] = eventBytes.length;

  let offset = header;
  for (const part of [joinRefBytes, refBytes, topicBytes, eventBytes, data]) {
    bytes.set(part, offset);
    offset += part.length;
  }

  return buffer;
}

/**
 * Reads a frame **coming from the server**. Returns null for anything
 * malformed rather than throwing: a bad frame must not take down the socket
 * that carries every other channel.
 *
 * The direction is in the name because the two directions are not symmetric:
 * a client push carries a `ref` and a server push does not, so the output of
 * `encodePush` is deliberately *not* readable here. Phoenix chose that
 * asymmetry; naming the function `decodeFrame` only hid it.
 */
export function decodeServerFrame(buffer: ArrayBuffer): BinaryFrame | null {
  const bytes = new Uint8Array(buffer);
  if (bytes.length < 1) return null;

  const kind = bytes[0];

  if (kind === BROADCAST) {
    if (bytes.length < 3) return null;
    const topicSize = bytes[1]!;
    const eventSize = bytes[2]!;
    let offset = 3;
    if (bytes.length < offset + topicSize + eventSize) return null;

    const topic = decoder.decode(bytes.subarray(offset, (offset += topicSize)));
    const event = decoder.decode(bytes.subarray(offset, (offset += eventSize)));

    return { kind: BROADCAST, topic, event, ref: null, joinRef: null, data: bytes.subarray(offset) };
  }

  if (kind === PUSH) {
    // No ref on this side — see the note on this function.
    if (bytes.length < 4) return null;
    const joinRefSize = bytes[1]!;
    const topicSize = bytes[2]!;
    const eventSize = bytes[3]!;
    let offset = 4;
    if (bytes.length < offset + joinRefSize + topicSize + eventSize) return null;

    const joinRef = decoder.decode(bytes.subarray(offset, (offset += joinRefSize)));
    const topic = decoder.decode(bytes.subarray(offset, (offset += topicSize)));
    const event = decoder.decode(bytes.subarray(offset, (offset += eventSize)));

    return { kind: PUSH, topic, event, ref: null, joinRef, data: bytes.subarray(offset) };
  }

  if (kind === REPLY) {
    if (bytes.length < 5) return null;
    const joinRefSize = bytes[1]!;
    const refSize = bytes[2]!;
    const topicSize = bytes[3]!;
    const statusSize = bytes[4]!;
    let offset = 5;
    if (bytes.length < offset + joinRefSize + refSize + topicSize + statusSize) return null;

    const joinRef = decoder.decode(bytes.subarray(offset, (offset += joinRefSize)));
    const ref = decoder.decode(bytes.subarray(offset, (offset += refSize)));
    const topic = decoder.decode(bytes.subarray(offset, (offset += topicSize)));
    const status = decoder.decode(bytes.subarray(offset, (offset += statusSize)));

    return { kind: REPLY, topic, event: status, ref, joinRef, data: bytes.subarray(offset) };
  }

  return null;
}
