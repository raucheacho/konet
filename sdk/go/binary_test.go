package konet

import (
	"bytes"
	"strings"
	"testing"
)

// Le cadrage binaire de Phoenix v2.
//
// These assertions are transcribed from Phoenix's own serializer rather than
// from a running server, deliberately: they are what pins the SDK to the
// protocol, so they state the byte layout rather than agree with whatever the
// code currently emits. The JavaScript SDK carries the same table.

func TestEncodeBinaryPushLayout(t *testing.T) {
	frame, err := encodeBinaryPush("7", "12", "room:x", "a", []byte{0xAA, 0xBB})
	if err != nil {
		t.Fatal(err)
	}

	if frame[0] != binaryPush {
		t.Errorf("type = %d, attendu %d", frame[0], binaryPush)
	}
	if frame[1] != 1 || frame[2] != 2 || frame[3] != 6 || frame[4] != 1 {
		t.Errorf("tailles = %v, attendu [1 2 6 1]", frame[1:5])
	}
	if got := string(frame[5:15]); got != "712room:xa" {
		t.Errorf("champs = %q", got)
	}
	if !bytes.Equal(frame[15:], []byte{0xAA, 0xBB}) {
		t.Errorf("données = %v", frame[15:])
	}
}

func TestEncodeBinaryPushCopiesData(t *testing.T) {
	scratch := []byte{1, 2, 3}
	frame, err := encodeBinaryPush("1", "1", "t", "a", scratch)
	if err != nil {
		t.Fatal(err)
	}

	// An audio path reuses one frame buffer every 20 ms; aliasing it would
	// send whatever the next frame happens to contain.
	copy(scratch, []byte{9, 9, 9})

	if !bytes.Equal(frame[len(frame)-3:], []byte{1, 2, 3}) {
		t.Errorf("les données ont suivi le tampon de l'appelant : %v", frame[len(frame)-3:])
	}
}

func TestEncodeBinaryPushRejectsOversizedField(t *testing.T) {
	// A truncated topic would deliver audio to a different room.
	if _, err := encodeBinaryPush("1", "1", strings.Repeat("r", 256), "a", nil); err == nil {
		t.Fatal("un topic de 256 octets doit être refusé")
	}
}

func TestDecodeBroadcast(t *testing.T) {
	raw := append([]byte{binaryBroadcast, 6, 1}, []byte("room:xa")...)
	raw = append(raw, 7, 8)

	frame, err := decodeServerBinaryFrame(raw)
	if err != nil {
		t.Fatal(err)
	}
	if frame.Topic != "room:x" || frame.Event != "a" {
		t.Errorf("topic/event = %q/%q", frame.Topic, frame.Event)
	}
	if !bytes.Equal(frame.Data, []byte{7, 8}) {
		t.Errorf("données = %v", frame.Data)
	}
}

func TestDecodeServerPushHasNoRef(t *testing.T) {
	raw := append([]byte{binaryPush, 1, 6, 1}, []byte("9room:xa")...)
	raw = append(raw, 5)

	frame, err := decodeServerBinaryFrame(raw)
	if err != nil {
		t.Fatal(err)
	}
	if frame.JoinRef != "9" || frame.Ref != "" {
		t.Errorf("join_ref/ref = %q/%q", frame.JoinRef, frame.Ref)
	}
}

func TestDecodeReplyCarriesStatus(t *testing.T) {
	raw := append([]byte{binaryReply, 1, 2, 6, 5}, []byte("912room:xerror")...)

	frame, err := decodeServerBinaryFrame(raw)
	if err != nil {
		t.Fatal(err)
	}
	if frame.Ref != "12" || frame.Event != "error" {
		t.Errorf("ref/status = %q/%q", frame.Ref, frame.Event)
	}
}

func TestDecodeCountsBytesNotRunes(t *testing.T) {
	// "équipe" is 7 bytes for 6 runes: the case where using rune length as a
	// byte length silently shifts every field after it.
	topic := "room:équipe"
	raw := append([]byte{binaryBroadcast, byte(len(topic)), 1}, []byte(topic+"a")...)
	raw = append(raw, 1, 2, 3, 4)

	frame, err := decodeServerBinaryFrame(raw)
	if err != nil {
		t.Fatal(err)
	}
	if frame.Topic != topic {
		t.Errorf("topic = %q, attendu %q", frame.Topic, topic)
	}
	if !bytes.Equal(frame.Data, []byte{1, 2, 3, 4}) {
		t.Errorf("données = %v", frame.Data)
	}
}

func TestDecodeRejectsTruncatedFrame(t *testing.T) {
	// One bad frame must not take down the socket every other channel shares,
	// so these report an error rather than panicking on a slice bound.
	for name, raw := range map[string][]byte{
		"vide":               {},
		"diffusion tronquée": {binaryBroadcast, 200, 200, 1},
		"réponse tronquée":   {binaryReply, 9, 9, 9, 9, 1},
		"type inconnu":       {99, 1, 2},
	} {
		if _, err := decodeServerBinaryFrame(raw); err == nil {
			t.Errorf("%s : une erreur était attendue", name)
		}
	}
}
