package konet

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// Reconnexion, re-join et liveness.
//
// These run against a real websocket server rather than a stub, because what is
// under test is the client's behaviour on the wire: which frames it re-sends
// after a drop, and whether it notices a socket that is open locally and dead
// on the other end.

type fakeServer struct {
	*httptest.Server

	mu         sync.Mutex
	conns      int
	joins      []string
	heartbeats int
	// joinModes is the binary_mode each join asked for, "" when it asked for
	// none, in the same order as joins.
	joinModes []string

	// dropFirstJoin closes the connection right after answering the first join
	// it ever sees, simulating a network drop mid-session.
	dropFirstJoin bool
	dropped       bool
	// answerHeartbeat off means the socket stays open but nothing replies —
	// the case a dropped connection never signals.
	answerHeartbeat bool
}

func newFakeServer(t *testing.T) *fakeServer {
	t.Helper()
	f := &fakeServer{answerHeartbeat: true}
	f.Server = httptest.NewServer(http.HandlerFunc(f.handle))
	t.Cleanup(f.Close)
	return f
}

func (f *fakeServer) wsURL() string {
	return "ws" + strings.TrimPrefix(f.URL, "http") + "/socket"
}

func (f *fakeServer) handle(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	defer conn.CloseNow()

	f.mu.Lock()
	f.conns++
	f.mu.Unlock()

	ctx := r.Context()
	for {
		typ, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		if typ == websocket.MessageBinary {
			continue
		}

		var raw []json.RawMessage
		if err := json.Unmarshal(data, &raw); err != nil || len(raw) != 5 {
			continue
		}
		var joinRef, ref, topic, event *string
		json.Unmarshal(raw[0], &joinRef)
		json.Unmarshal(raw[1], &ref)
		json.Unmarshal(raw[2], &topic)
		json.Unmarshal(raw[3], &event)
		if topic == nil || event == nil || ref == nil {
			continue
		}

		if *topic == "phoenix" {
			f.mu.Lock()
			f.heartbeats++
			answer := f.answerHeartbeat
			f.mu.Unlock()
			if answer {
				f.reply(ctx, conn, *ref, "phoenix")
			}
			continue
		}

		if *event == "phx_join" {
			var payload struct {
				BinaryMode string `json:"binary_mode"`
			}
			json.Unmarshal(raw[4], &payload)

			f.mu.Lock()
			f.joins = append(f.joins, *topic)
			f.joinModes = append(f.joinModes, payload.BinaryMode)
			drop := f.dropFirstJoin && !f.dropped
			if drop {
				f.dropped = true
			}
			f.mu.Unlock()

			// Like the server: the mode in force comes back in the reply.
			response := map[string]interface{}{}
			if payload.BinaryMode != "" {
				response["binary_mode"] = payload.BinaryMode
			}
			f.replyWith(ctx, conn, *ref, *topic, response)
			if drop {
				conn.Close(websocket.StatusAbnormalClosure, "network drop")
				return
			}
		}
	}
}

func (f *fakeServer) reply(ctx context.Context, conn *websocket.Conn, ref, topic string) {
	f.replyWith(ctx, conn, ref, topic, map[string]interface{}{})
}

func (f *fakeServer) replyWith(ctx context.Context, conn *websocket.Conn, ref, topic string, response map[string]interface{}) {
	frame := []interface{}{nil, ref, topic, "phx_reply",
		map[string]interface{}{"status": "ok", "response": response}}
	payload, _ := json.Marshal(frame)
	conn.Write(ctx, websocket.MessageText, payload)
}

func (f *fakeServer) snapshot() (conns int, joins []string, heartbeats int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.conns, append([]string{}, f.joins...), f.heartbeats
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func testOptions() ClientOptions {
	return ClientOptions{
		HeartbeatInterval: time.Hour, // out of the way unless a test wants it
		ReconnectDelay:    time.Millisecond,
		MaxReconnectTries: 5,
	}
}

// ── Re-join ────────────────────────────────────────────────────────────────

func TestRejoinsAfterDroppedConnection(t *testing.T) {
	server := newFakeServer(t)
	server.dropFirstJoin = true

	ctx := context.Background()
	client := New(server.wsURL(), "tok", testOptions())
	if err := client.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	defer client.Disconnect()

	ch := client.Channel("room:lobby")
	if err := ch.Subscribe(ctx); err != nil {
		t.Fatal(err)
	}

	// The server dropped us right after that join. The client must open a new
	// socket and re-issue phx_join on it — otherwise it looks connected while
	// every send lands on a topic the socket never joined.
	waitFor(t, "a re-join on a second connection", func() bool {
		conns, joins, _ := server.snapshot()
		return conns >= 2 && len(joins) >= 2
	})

	_, joins, _ := server.snapshot()
	for _, topic := range joins {
		if topic != "room:lobby" {
			t.Fatalf("unexpected join on %q", topic)
		}
	}

	waitFor(t, "the channel to be joined again", ch.Joined)
}

func TestDoesNotRejoinAChannelThatWasLeft(t *testing.T) {
	server := newFakeServer(t)

	ctx := context.Background()
	client := New(server.wsURL(), "tok", testOptions())
	if err := client.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	defer client.Disconnect()

	kept := client.Channel("room:kept")
	left := client.Channel("room:left")
	if err := kept.Subscribe(ctx); err != nil {
		t.Fatal(err)
	}
	if err := left.Subscribe(ctx); err != nil {
		t.Fatal(err)
	}
	if err := left.Unsubscribe(); err != nil {
		t.Fatal(err)
	}

	// Force a drop now that both channels have been joined once.
	server.mu.Lock()
	server.dropFirstJoin = true
	server.dropped = false
	server.mu.Unlock()

	if err := kept.Unsubscribe(); err != nil {
		t.Fatal(err)
	}
	if err := kept.Subscribe(ctx); err != nil && err != ErrSocketClosed {
		t.Fatal(err)
	}

	waitFor(t, "a reconnect", func() bool {
		conns, _, _ := server.snapshot()
		return conns >= 2
	})
	time.Sleep(150 * time.Millisecond)

	_, joins, _ := server.snapshot()
	var leftRejoined bool
	for _, topic := range joins[2:] {
		if topic == "room:left" {
			leftRejoined = true
		}
	}
	if leftRejoined {
		t.Fatal("a channel the caller unsubscribed from must never be re-joined")
	}
}

func TestSendFailsLoudlyWhileDisconnected(t *testing.T) {
	server := newFakeServer(t)
	server.dropFirstJoin = true

	ctx := context.Background()
	client := New(server.wsURL(), "tok", ClientOptions{
		HeartbeatInterval: time.Hour,
		ReconnectDelay:    time.Hour, // never actually reconnect during the test
		MaxReconnectTries: 1,
	})
	if err := client.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	defer client.Disconnect()

	ch := client.Channel("room:lobby")
	if err := ch.Subscribe(ctx); err != nil {
		t.Fatal(err)
	}

	waitFor(t, "the channel to notice the socket died", func() bool { return !ch.Joined() })

	if err := ch.Send("message", map[string]any{"text": "lost"}); err == nil {
		t.Fatal("Send must fail once the socket that carried the join is gone")
	}
}

// ── Goroutine hygiene ──────────────────────────────────────────────────────

func TestNoGoroutineLeakAcrossReconnects(t *testing.T) {
	server := newFakeServer(t)

	ctx := context.Background()
	client := New(server.wsURL(), "tok", testOptions())
	if err := client.Connect(ctx); err != nil {
		t.Fatal(err)
	}

	ch := client.Channel("room:lobby")
	if err := ch.Subscribe(ctx); err != nil {
		t.Fatal(err)
	}

	settle := func() int {
		var last int
		for i := 0; i < 40; i++ {
			time.Sleep(10 * time.Millisecond)
			last = runtime.NumGoroutine()
		}
		return last
	}
	baseline := settle()

	// Three forced drops. Before the fix, each Connect spawned a fresh
	// heartbeatLoop that only Disconnect could stop, so the count climbed by
	// one per reconnect and the client sent one extra heartbeat per interval.
	for i := 0; i < 3; i++ {
		server.mu.Lock()
		server.dropFirstJoin = true
		server.dropped = false
		before := server.conns
		server.mu.Unlock()

		_ = ch.Unsubscribe()
		_ = ch.Subscribe(ctx)

		waitFor(t, "a reconnect", func() bool {
			conns, _, _ := server.snapshot()
			return conns > before
		})
	}

	after := settle()
	client.Disconnect()

	if after > baseline+2 {
		t.Fatalf("goroutines leaked across reconnects: baseline %d, after %d", baseline, after)
	}
}

// ── Liveness ───────────────────────────────────────────────────────────────

func TestUnansweredHeartbeatForcesReconnect(t *testing.T) {
	server := newFakeServer(t)
	server.answerHeartbeat = false

	ctx := context.Background()
	client := New(server.wsURL(), "tok", ClientOptions{
		HeartbeatInterval: 40 * time.Millisecond,
		ReconnectDelay:    time.Millisecond,
		MaxReconnectTries: 5,
	})
	if err := client.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	defer client.Disconnect()

	if err := client.Channel("room:lobby").Subscribe(ctx); err != nil {
		t.Fatal(err)
	}

	// The socket stays open; the server simply never answers. Only the missing
	// heartbeat reply can reveal it.
	waitFor(t, "the dead-but-open socket to be replaced", func() bool {
		conns, _, heartbeats := server.snapshot()
		return conns >= 2 && heartbeats >= 2
	})
}

func TestAnsweredHeartbeatKeepsTheSocket(t *testing.T) {
	server := newFakeServer(t)

	ctx := context.Background()
	client := New(server.wsURL(), "tok", ClientOptions{
		HeartbeatInterval: 20 * time.Millisecond,
		ReconnectDelay:    time.Millisecond,
		MaxReconnectTries: 5,
	})
	if err := client.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	defer client.Disconnect()

	if err := client.Channel("room:lobby").Subscribe(ctx); err != nil {
		t.Fatal(err)
	}

	waitFor(t, "several heartbeats", func() bool {
		_, _, heartbeats := server.snapshot()
		return heartbeats >= 4
	})

	if conns, _, _ := server.snapshot(); conns != 1 {
		t.Fatalf("answered probes must not reconnect: %d connections", conns)
	}
}

// ── Handler registration ───────────────────────────────────────────────────

func TestUnsubscribeRemovesOnlyItsOwnHandler(t *testing.T) {
	ch := newChannel("room:x", func(phxFrame) error { return nil },
		func(string, string, string, string, []byte) error { return nil },
		func() string { return "1" })

	var got []string
	// Deliberately closures over the same body: comparing code pointers, as the
	// old implementation did, cannot tell these apart.
	make := func(name string) EventHandler {
		return func(interface{}) { got = append(got, name) }
	}

	offA := ch.On("evt", make("a"))
	ch.On("evt", make("b"))
	ch.On("evt", make("c"))

	offA()

	ch.mu.RLock()
	subs := append([]eventSub{}, ch.handlers["evt"]...)
	ch.mu.RUnlock()
	for _, sub := range subs {
		sub.fn(nil)
	}

	if len(got) != 2 || got[0] != "b" || got[1] != "c" {
		t.Fatalf("expected b and c to survive in order, got %v", got)
	}
}

func TestBinaryUnsubscribeRemovesOnlyItsOwnHandler(t *testing.T) {
	ch := newChannel("room:x", func(phxFrame) error { return nil },
		func(string, string, string, string, []byte) error { return nil },
		func() string { return "1" })

	var got []string
	offA := ch.OnBinary("a", func([]byte) { got = append(got, "a") })
	ch.OnBinary("a", func([]byte) { got = append(got, "b") })
	ch.OnBinary("a", func([]byte) { got = append(got, "c") })

	// Removing the first shifted every later index in the old implementation,
	// so this second removal used to take out the wrong handler.
	offA()

	ch.receiveBinary("a", []byte{1})

	if len(got) != 2 || got[0] != "b" || got[1] != "c" {
		t.Fatalf("expected b and c to survive in order, got %v", got)
	}
}

// ── Binary mode ────────────────────────────────────────────────────────────

func TestDefaultJoinAsksForNoModeAndReadsExclusive(t *testing.T) {
	server := newFakeServer(t)
	ctx := context.Background()
	client := New(server.wsURL(), "tok", testOptions())
	if err := client.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	defer client.Disconnect()

	ch := client.Channel("room:walkie")
	if err := ch.Subscribe(ctx); err != nil {
		t.Fatal(err)
	}

	server.mu.Lock()
	modes := append([]string{}, server.joinModes...)
	server.mu.Unlock()
	// Unchanged on the wire for every existing push-to-talk client.
	if len(modes) != 1 || modes[0] != "" {
		t.Fatalf("default join asked for %q", modes)
	}
	// The reply carries no mode, as from a server older than it.
	if got := ch.BinaryMode(); got != BinaryExclusive {
		t.Fatalf("BinaryMode() = %q, want exclusive", got)
	}
}

func TestMultiplexIsAskedOnEveryJoin(t *testing.T) {
	server := newFakeServer(t)
	server.dropFirstJoin = true

	ctx := context.Background()
	client := New(server.wsURL(), "tok", testOptions())
	if err := client.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	defer client.Disconnect()

	ch := client.Channel("room:call", WithBinaryMode(BinaryMultiplex))
	if err := ch.Subscribe(ctx); err != nil {
		t.Fatal(err)
	}

	// The server forgets a topic's mode once it empties, so a rejoin that
	// dropped the option would come back exclusive — or be refused.
	waitFor(t, "a re-join on a second connection", func() bool {
		_, joins, _ := server.snapshot()
		return len(joins) >= 2
	})
	waitFor(t, "the channel to be joined again", ch.Joined)

	server.mu.Lock()
	modes := append([]string{}, server.joinModes...)
	server.mu.Unlock()
	for i, mode := range modes {
		if mode != "multiplex" {
			t.Fatalf("join %d asked for %q, want multiplex", i, mode)
		}
	}
	if got := ch.BinaryMode(); got != BinaryMultiplex {
		t.Fatalf("BinaryMode() = %q, want multiplex", got)
	}
}

func TestChannelRefusesADifferentModeForAnExistingTopic(t *testing.T) {
	client := New("ws://unused", "tok", testOptions())
	ch := client.Channel("room:call", WithBinaryMode(BinaryMultiplex))

	if client.Channel("room:call") != ch {
		t.Fatal("a plain lookup must return the existing channel")
	}
	if client.Channel("room:call", WithBinaryMode(BinaryMultiplex)) != ch {
		t.Fatal("asking for the same mode must return the existing channel")
	}

	defer func() {
		if recover() == nil {
			t.Fatal("asking for the other mode must not silently return the channel")
		}
	}()
	client.Channel("room:call", WithBinaryMode(BinaryExclusive))
}

func stamped(sender string, data ...byte) []byte {
	return append(append([]byte{byte(len(sender))}, sender...), data...)
}

func TestMultiplexFramesCarryTheirSender(t *testing.T) {
	ch := newChannel("room:call", nil, nil, func() string { return "1" }, WithBinaryMode(BinaryMultiplex))
	ch.confirmedMode = BinaryMultiplex // as after a join the server confirmed

	type heard struct {
		data   string
		sender string
	}
	var got []heard
	var plain []string
	ch.OnBinaryFrom("a", func(data []byte, sender string) { got = append(got, heard{string(data), sender}) })
	ch.OnBinary("a", func(data []byte) { plain = append(plain, string(data)) })

	ch.receiveBinary("a", stamped("alice", 'x'))
	ch.receiveBinary("a", stamped("bob", 'x'))
	// Too short for its own prefix: dropped, not delivered half-parsed.
	ch.receiveBinary("a", []byte{9})

	want := []heard{{"x", "alice"}, {"x", "bob"}}
	if len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("OnBinaryFrom got %v, want %v", got, want)
	}
	// A sender-less handler still gets the data, prefix removed.
	if len(plain) != 2 || plain[0] != "x" || plain[1] != "x" {
		t.Fatalf("OnBinary got %q", plain)
	}
}

func TestExclusiveFramesAreLeftUntouched(t *testing.T) {
	ch := newChannel("room:walkie", nil, nil, func() string { return "1" })
	ch.confirmedMode = BinaryExclusive

	var data []byte
	sender := "unset"
	ch.OnBinaryFrom("a", func(d []byte, s string) { data, sender = append([]byte(nil), d...), s })
	ch.receiveBinary("a", []byte{5, 1, 2})

	// The leading 5 is data here, not a length: exclusive frames have no prefix.
	if string(data) != string([]byte{5, 1, 2}) || sender != "" {
		t.Fatalf("got %v from %q", data, sender)
	}
}

// ── Backoff and status ─────────────────────────────────────────────────────

func TestReconnectDelayJittersHalfOfEachStep(t *testing.T) {
	cases := []struct {
		attempt int
		random  float64
		want    time.Duration
	}{
		{0, 0, 500 * time.Millisecond},
		{0, 1, time.Second},
		{2, 0.5, 3 * time.Second},
		{20, 1, 30 * time.Second},  // ceiling
		{20, 0, 15 * time.Second},  // half the ceiling at least
		{200, 1, 30 * time.Second}, // overflowing step still capped
	}
	for _, tc := range cases {
		got := reconnectDelay(time.Second, tc.attempt, func() float64 { return tc.random })
		if got != tc.want {
			t.Errorf("attempt %d random %v: got %v, want %v", tc.attempt, tc.random, got, tc.want)
		}
	}
}

func TestStatusReportsEachStepIncludingGivingUp(t *testing.T) {
	server := newFakeServer(t)
	server.dropFirstJoin = true

	var mu sync.Mutex
	var states []StatusState
	opts := testOptions()
	opts.MaxReconnectTries = 2
	opts.OnStatus = func(s Status) {
		mu.Lock()
		states = append(states, s.State)
		mu.Unlock()
		if s.State == StatusReconnecting && (s.Attempt < 1 || s.Delay <= 0) {
			t.Errorf("reconnecting status without attempt/delay: %+v", s)
		}
	}

	ctx := context.Background()
	client := New(server.wsURL(), "tok", opts)
	if err := client.Connect(ctx); err != nil {
		t.Fatal(err)
	}

	// The join is answered then the socket dropped; with the server gone, both
	// retries fail and the client gives up.
	server.Close()
	_ = client.Channel("room:lobby").Subscribe(ctx)

	snapshot := func() []StatusState {
		mu.Lock()
		defer mu.Unlock()
		return append([]StatusState{}, states...)
	}
	waitFor(t, "the client to give up", func() bool {
		s := snapshot()
		return len(s) > 0 && s[len(s)-1] == StatusFailed
	})

	want := []StatusState{
		StatusConnecting, StatusConnected,
		StatusReconnecting, StatusConnecting,
		StatusReconnecting, StatusConnecting,
		StatusFailed,
	}
	if got := snapshot(); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("got %v, want %v", got, want)
	}

	client.Disconnect()
	client.Disconnect()
	if got := snapshot(); got[len(got)-1] != StatusDisconnected || len(got) != len(want)+1 {
		t.Fatalf("after Disconnect twice: %v", got)
	}
}

// ── Binary refusals ────────────────────────────────────────────────────────

func refusal(ref, reason string) phxFrame {
	return phxFrame{Ref: &ref, Topic: "room:t", Event: "phx_reply",
		Payload: map[string]interface{}{"status": "error", "response": map[string]interface{}{"reason": reason}}}
}

func TestBinaryFramesCarryARecognisableRef(t *testing.T) {
	var sentRef string
	ch := newChannel("room:t", nil, func(_, ref, _, _ string, _ []byte) error {
		sentRef = ref
		return nil
	}, func() string { return "7" })
	ch.state = channelJoined

	if err := ch.SendBinary("a", []byte{1}); err != nil {
		t.Fatal(err)
	}
	if sentRef != "b7" {
		t.Fatalf("binary ref = %q, want b7", sentRef)
	}
}

func TestBinaryRefusalsAreReportedOncePerReasonPerSecond(t *testing.T) {
	ch := newChannel("room:t", nil, nil, func() string { return "1" })
	got := make(chan BinaryError, 8)
	ch.On("binary_error", func(p interface{}) { got <- p.(BinaryError) })

	ch.receive(refusal("b1", "floor_required"))
	ch.receive(refusal("b2", "floor_required")) // same second: folded
	ch.receive(refusal("b3", "rate_limited"))   // another reason: reported
	ch.receive(refusal("4", "whatever"))        // not a binary ref: ignored

	seen := map[string]bool{}
	for i := 0; i < 2; i++ {
		select {
		case e := <-got:
			if e.Topic != "room:t" {
				t.Errorf("topic = %q", e.Topic)
			}
			seen[e.Reason] = true
		case <-time.After(time.Second):
			t.Fatalf("only %v reported", seen)
		}
	}
	if !seen["floor_required"] || !seen["rate_limited"] {
		t.Fatalf("reported %v", seen)
	}
	select {
	case e := <-got:
		t.Fatalf("unexpected extra report %+v", e)
	case <-time.After(100 * time.Millisecond):
	}

	// Once the second has passed, the same reason is reported again.
	ch.mu.Lock()
	ch.binaryErrorAt["floor_required"] = time.Now().Add(-2 * time.Second)
	ch.mu.Unlock()
	ch.receive(refusal("b5", "floor_required"))
	select {
	case e := <-got:
		if e.Reason != "floor_required" {
			t.Fatalf("got %+v", e)
		}
	case <-time.After(time.Second):
		t.Fatal("not reported after the window")
	}
}
