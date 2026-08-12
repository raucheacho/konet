package konet

import (
	"errors"
	"fmt"
)

// Le format binaire de Phoenix Channels v2.
//
// Phoenix carries binary payloads in their own framing rather than base64
// inside JSON — the difference matters for anything at a media rate, where a
// third of overhead and a JSON parse per 20 ms frame is not free.
//
// Three shapes travel on the wire, told apart by their first byte. The field
// order is transcribed from Phoenix's own serializer
// (Phoenix.Socket.V2.JSONSerializer) and must stay in step with it:
//
//	push      0 | join_ref_size | ref_size | topic_size | event_size | … | data
//	reply     1 | join_ref_size | ref_size | topic_size | status_size | … | data
//	broadcast 2 | topic_size | event_size | topic | event | data
//
// Every size is one byte, so each field is capped at 255. That is checked when
// encoding, because a silently truncated topic would deliver audio to the
// wrong room.
const (
	binaryPush      byte = 0
	binaryReply     byte = 1
	binaryBroadcast byte = 2
)

// ErrShortFrame reports a frame that ended before its declared fields did.
var ErrShortFrame = errors.New("konet: trame binaire tronquée")

// BinaryFrame is a decoded binary message from the server.
type BinaryFrame struct {
	Kind  byte
	Topic string
	// Event name, or the reply status ("ok" / "error").
	Event   string
	Ref     string
	JoinRef string
	Data    []byte
}

func sizedField(value, name string) ([]byte, error) {
	bytes := []byte(value)
	if len(bytes) > 255 {
		return nil, fmt.Errorf("konet: %s dépasse 255 octets (%d)", name, len(bytes))
	}
	return bytes, nil
}

// encodeBinaryPush builds a client push. data is copied into the frame, so the
// caller may reuse its buffer immediately — which an audio path does, every
// 20 ms.
func encodeBinaryPush(joinRef, ref, topic, event string, data []byte) ([]byte, error) {
	joinRefBytes, err := sizedField(joinRef, "join_ref")
	if err != nil {
		return nil, err
	}
	refBytes, err := sizedField(ref, "ref")
	if err != nil {
		return nil, err
	}
	topicBytes, err := sizedField(topic, "topic")
	if err != nil {
		return nil, err
	}
	eventBytes, err := sizedField(event, "event")
	if err != nil {
		return nil, err
	}

	const header = 5
	out := make([]byte, 0, header+len(joinRefBytes)+len(refBytes)+len(topicBytes)+len(eventBytes)+len(data))

	out = append(out, binaryPush,
		byte(len(joinRefBytes)), byte(len(refBytes)),
		byte(len(topicBytes)), byte(len(eventBytes)))
	out = append(out, joinRefBytes...)
	out = append(out, refBytes...)
	out = append(out, topicBytes...)
	out = append(out, eventBytes...)
	out = append(out, data...)

	return out, nil
}

// decodeServerBinaryFrame reads a frame coming *from the server*.
//
// The direction is in the name because the two directions are not symmetric: a
// client push carries a ref and a server push does not, so the output of
// encodeBinaryPush is deliberately not readable here. Phoenix chose that
// asymmetry; a name like decodeFrame would only hide it.
func decodeServerBinaryFrame(raw []byte) (BinaryFrame, error) {
	if len(raw) < 1 {
		return BinaryFrame{}, ErrShortFrame
	}

	// take consumes n bytes, or reports that the frame ended early.
	offset := 0
	take := func(n int) ([]byte, bool) {
		if offset+n > len(raw) {
			return nil, false
		}
		out := raw[offset : offset+n]
		offset += n
		return out, true
	}

	switch raw[0] {
	case binaryBroadcast:
		if len(raw) < 3 {
			return BinaryFrame{}, ErrShortFrame
		}
		topicSize, eventSize := int(raw[1]), int(raw[2])
		offset = 3

		topic, ok := take(topicSize)
		if !ok {
			return BinaryFrame{}, ErrShortFrame
		}
		event, ok := take(eventSize)
		if !ok {
			return BinaryFrame{}, ErrShortFrame
		}

		return BinaryFrame{
			Kind:  binaryBroadcast,
			Topic: string(topic),
			Event: string(event),
			Data:  raw[offset:],
		}, nil

	case binaryPush:
		if len(raw) < 4 {
			return BinaryFrame{}, ErrShortFrame
		}
		joinRefSize, topicSize, eventSize := int(raw[1]), int(raw[2]), int(raw[3])
		offset = 4

		joinRef, ok := take(joinRefSize)
		if !ok {
			return BinaryFrame{}, ErrShortFrame
		}
		topic, ok := take(topicSize)
		if !ok {
			return BinaryFrame{}, ErrShortFrame
		}
		event, ok := take(eventSize)
		if !ok {
			return BinaryFrame{}, ErrShortFrame
		}

		return BinaryFrame{
			Kind:    binaryPush,
			JoinRef: string(joinRef),
			Topic:   string(topic),
			Event:   string(event),
			Data:    raw[offset:],
		}, nil

	case binaryReply:
		if len(raw) < 5 {
			return BinaryFrame{}, ErrShortFrame
		}
		joinRefSize, refSize := int(raw[1]), int(raw[2])
		topicSize, statusSize := int(raw[3]), int(raw[4])
		offset = 5

		joinRef, ok := take(joinRefSize)
		if !ok {
			return BinaryFrame{}, ErrShortFrame
		}
		ref, ok := take(refSize)
		if !ok {
			return BinaryFrame{}, ErrShortFrame
		}
		topic, ok := take(topicSize)
		if !ok {
			return BinaryFrame{}, ErrShortFrame
		}
		status, ok := take(statusSize)
		if !ok {
			return BinaryFrame{}, ErrShortFrame
		}

		return BinaryFrame{
			Kind:    binaryReply,
			JoinRef: string(joinRef),
			Ref:     string(ref),
			Topic:   string(topic),
			Event:   string(status),
			Data:    raw[offset:],
		}, nil
	}

	return BinaryFrame{}, fmt.Errorf("konet: type de trame binaire inconnu (%d)", raw[0])
}
