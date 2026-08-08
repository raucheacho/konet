"""Le format binaire de Phoenix Channels v2.

Phoenix carries binary payloads in their own framing rather than base64 inside
JSON — the difference matters for anything at a media rate, where a third of
overhead and a JSON parse per 20 ms frame is not free.

Three shapes travel on the wire, told apart by their first byte. The field
order is transcribed from Phoenix's own serializer
(``Phoenix.Socket.V2.JSONSerializer``) and must stay in step with it::

    push      0 | join_ref_size | ref_size | topic_size | event_size | … | data
    reply     1 | join_ref_size | ref_size | topic_size | status_size | … | data
    broadcast 2 | topic_size | event_size | topic | event | data

Every size is one byte, so each field is capped at 255. That is checked when
encoding, because a silently truncated topic would deliver audio to the wrong
room.

The same table appears in the JavaScript and Go SDKs. It is written out in each
rather than shared, because a wire format is the one thing every client must
agree on independently.
"""

from __future__ import annotations

from dataclasses import dataclass

PUSH = 0
REPLY = 1
BROADCAST = 2


@dataclass(frozen=True)
class BinaryFrame:
    """A decoded binary message from the server."""

    kind: int
    topic: str
    #: Event name, or the reply status ("ok" / "error").
    event: str
    ref: str | None
    join_ref: str | None
    data: bytes


def _sized(value: str, field: str) -> bytes:
    encoded = value.encode("utf-8")
    if len(encoded) > 255:
        raise ValueError(f"{field} dépasse 255 octets ({len(encoded)})")
    return encoded


def encode_push(join_ref: str, ref: str, topic: str, event: str, data: bytes) -> bytes:
    """Build a client push.

    ``data`` is copied into the frame, so the caller may reuse its buffer
    immediately — which an audio path does, every 20 ms.
    """
    join_ref_bytes = _sized(join_ref, "join_ref")
    ref_bytes = _sized(ref, "ref")
    topic_bytes = _sized(topic, "topic")
    event_bytes = _sized(event, "event")

    return b"".join(
        (
            bytes(
                (
                    PUSH,
                    len(join_ref_bytes),
                    len(ref_bytes),
                    len(topic_bytes),
                    len(event_bytes),
                )
            ),
            join_ref_bytes,
            ref_bytes,
            topic_bytes,
            event_bytes,
            bytes(data),
        )
    )


def decode_server_frame(raw: bytes) -> BinaryFrame | None:
    """Read a frame coming *from the server*.

    Returns ``None`` for anything malformed rather than raising: a bad frame
    must not take down the socket that carries every other channel.

    The direction is in the name because the two directions are not symmetric:
    a client push carries a ref and a server push does not, so the output of
    :func:`encode_push` is deliberately *not* readable here. Phoenix chose that
    asymmetry; a name like ``decode_frame`` would only hide it.
    """
    if len(raw) < 1:
        return None

    kind = raw[0]

    if kind == BROADCAST:
        if len(raw) < 3:
            return None
        topic_size, event_size = raw[1], raw[2]
        offset = 3
        if len(raw) < offset + topic_size + event_size:
            return None

        topic = raw[offset : offset + topic_size].decode("utf-8", "replace")
        offset += topic_size
        event = raw[offset : offset + event_size].decode("utf-8", "replace")
        offset += event_size

        return BinaryFrame(BROADCAST, topic, event, None, None, raw[offset:])

    if kind == PUSH:
        # No ref on this side — see the note on this function.
        if len(raw) < 4:
            return None
        join_ref_size, topic_size, event_size = raw[1], raw[2], raw[3]
        offset = 4
        if len(raw) < offset + join_ref_size + topic_size + event_size:
            return None

        join_ref = raw[offset : offset + join_ref_size].decode("utf-8", "replace")
        offset += join_ref_size
        topic = raw[offset : offset + topic_size].decode("utf-8", "replace")
        offset += topic_size
        event = raw[offset : offset + event_size].decode("utf-8", "replace")
        offset += event_size

        return BinaryFrame(PUSH, topic, event, None, join_ref, raw[offset:])

    if kind == REPLY:
        if len(raw) < 5:
            return None
        join_ref_size, ref_size, topic_size, status_size = raw[1], raw[2], raw[3], raw[4]
        offset = 5
        if len(raw) < offset + join_ref_size + ref_size + topic_size + status_size:
            return None

        join_ref = raw[offset : offset + join_ref_size].decode("utf-8", "replace")
        offset += join_ref_size
        ref = raw[offset : offset + ref_size].decode("utf-8", "replace")
        offset += ref_size
        topic = raw[offset : offset + topic_size].decode("utf-8", "replace")
        offset += topic_size
        status = raw[offset : offset + status_size].decode("utf-8", "replace")
        offset += status_size

        return BinaryFrame(REPLY, topic, status, ref, join_ref, raw[offset:])

    return None
