"""Le cadrage binaire de Phoenix Channels v2.

Transcribed from Phoenix's own serializer rather than captured from a running
server: these assertions are what pin the SDK to the protocol, so they state
the byte layout instead of agreeing with whatever the code currently emits.

The JavaScript and Go SDKs carry the same table, deliberately duplicated — a
wire format is the one thing every client has to agree on independently.
"""

import pytest

from konet.binary import BROADCAST, PUSH, REPLY, decode_server_frame, encode_push


class TestEncodePush:
    def test_sizes_come_before_fields(self):
        frame = encode_push("7", "12", "room:x", "a", bytes([0xAA, 0xBB]))

        assert frame[:5] == bytes([PUSH, 1, 2, 6, 1])
        assert frame[5:15] == b"712room:xa"
        assert frame[15:] == bytes([0xAA, 0xBB])

    def test_payload_is_copied(self):
        scratch = bytearray([1, 2, 3])
        frame = encode_push("1", "1", "t", "a", scratch)

        # An audio path reuses one frame buffer every 20 ms; aliasing it would
        # send whatever the next frame happens to contain.
        scratch[:] = b"\x09\x09\x09"
        assert frame[-3:] == bytes([1, 2, 3])

    def test_oversized_field_is_refused_not_truncated(self):
        # A truncated topic would deliver audio to a different room.
        with pytest.raises(ValueError):
            encode_push("1", "1", "r" * 256, "a", b"")


class TestDecodeServerFrame:
    def test_broadcast(self):
        frame = decode_server_frame(bytes([BROADCAST, 6, 1]) + b"room:xa" + bytes([7, 8]))

        assert frame.topic == "room:x"
        assert frame.event == "a"
        assert frame.data == bytes([7, 8])

    def test_server_push_carries_no_ref(self):
        frame = decode_server_frame(bytes([PUSH, 1, 6, 1]) + b"9room:xa" + bytes([5]))

        assert frame.join_ref == "9"
        assert frame.ref is None

    def test_reply_carries_its_status(self):
        frame = decode_server_frame(bytes([REPLY, 1, 2, 6, 5]) + b"912room:xerror")

        assert frame.ref == "12"
        assert frame.event == "error"

    def test_counts_bytes_not_characters(self):
        # "équipe" is 7 bytes for 6 characters: the case where using character
        # length as a byte length silently shifts every field after it.
        topic = "room:équipe"
        raw = (
            bytes([BROADCAST, len(topic.encode()), 1])
            + (topic + "a").encode()
            + bytes([1, 2, 3, 4])
        )

        frame = decode_server_frame(raw)
        assert frame.topic == topic
        assert frame.data == bytes([1, 2, 3, 4])

    @pytest.mark.parametrize(
        "raw",
        [
            b"",
            bytes([BROADCAST, 200, 200, 1]),
            bytes([REPLY, 9, 9, 9, 9, 1]),
            bytes([99, 1, 2]),
        ],
        ids=["vide", "diffusion tronquée", "réponse tronquée", "type inconnu"],
    )
    def test_malformed_frame_returns_none(self, raw):
        # One bad frame must not take down the socket every other channel
        # shares, so this reports rather than raising.
        assert decode_server_frame(raw) is None

    def test_client_push_is_not_readable_here(self):
        # Stated as a test because it fooled the author of the JS SDK first:
        # encode_push produces the client-to-server shape, which has an extra
        # ref field. Feeding it here yields nonsense rather than an error.
        frame = decode_server_frame(encode_push("3", "44", "room:x", "a", bytes([1])))
        assert frame.topic != "room:x"
