package konet

import (
	"context"
	"encoding/json"
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
			f.mu.Lock()
			f.joins = append(f.joins, *topic)
			drop := f.dropFirstJoin && !f.dropped
			if drop {
				f.dropped = true
			}
			f.mu.Unlock()

			f.reply(ctx, conn, *ref, *topic)
			if drop {
				conn.Close(websocket.StatusAbnormalClosure, "network drop")
				return
			}
		}
	}
}

func (f *fakeServer) reply(ctx context.Context, conn *websocket.Conn, ref, topic string) {
	frame := []interface{}{nil, ref, topic, "phx_reply",
		map[string]interface{}{"status": "ok", "response": map[string]interface{}{}}}
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
