// Conformance scenario — Go SDK against a real konet-server.
// See ../README.md for the numbered steps.
package main

import (
	"context"
	"fmt"
	"os"
	"sync"
	"time"

	konet "github.com/raucheacho/konet/sdk/go"
)

var failures int

func pass(n int, name string) { fmt.Printf("PASS %d %s\n", n, name) }

func fail(n int, name, why string) {
	failures++
	fmt.Printf("FAIL %d %s: %s\n", n, name, why)
}

func check(n int, name string, ok bool, why string) {
	if ok {
		pass(n, name)
	} else {
		fail(n, name, why)
	}
}

// waiter collects the first payload delivered for an event.
type waiter struct {
	mu   sync.Mutex
	got  chan any
	once sync.Once
}

func newWaiter() *waiter { return &waiter{got: make(chan any, 8)} }

func (w *waiter) deliver(v any) {
	w.mu.Lock()
	defer w.mu.Unlock()
	select {
	case w.got <- v:
	default:
	}
}

func (w *waiter) wait(d time.Duration) (any, bool) {
	select {
	case v := <-w.got:
		return v, true
	case <-time.After(d):
		return nil, false
	}
}

func main() {
	url := env("KONET_URL", "ws://127.0.0.1:4009/socket")
	token := os.Getenv("KONET_TOKEN")
	// A second *identity*, not just a second socket: the floor is keyed on the
	// user id from the "sub" claim, so two connections sharing a token count as
	// one holder.
	tokenB := env("KONET_TOKEN_B", token)
	room := env("KONET_ROOM", fmt.Sprintf("room:conf-go-%d", time.Now().UnixNano()))

	if token == "" {
		fmt.Fprintln(os.Stderr, "KONET_TOKEN is required")
		os.Exit(2)
	}

	ctx := context.Background()
	opts := konet.ClientOptions{
		HeartbeatInterval: 30 * time.Second,
		ReconnectDelay:    time.Second,
		MaxReconnectTries: 3,
	}

	// 1 — connect
	a := konet.New(url, token, opts)
	b := konet.New(url, tokenB, opts)
	if err := a.Connect(ctx); err != nil {
		fail(1, "connect", err.Error())
		finish()
	}
	if err := b.Connect(ctx); err != nil {
		fail(1, "connect", err.Error())
		finish()
	}
	defer a.Disconnect()
	defer b.Disconnect()
	pass(1, "connect")

	chA := a.Channel(room)
	chB := b.Channel(room)

	// Handlers must be registered before the join, or the presence push that
	// immediately follows it is missed.
	presence := newWaiter()
	chA.On("presence_state", func(p any) { presence.deliver(p) })

	// 2 — join
	joinCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := chA.Subscribe(joinCtx); err != nil {
		fail(2, "join", err.Error())
		finish()
	}
	if err := chB.Subscribe(joinCtx); err != nil {
		fail(2, "join", err.Error())
		finish()
	}
	pass(2, "join")

	// 3 — presence
	_, ok := presence.wait(3 * time.Second)
	check(3, "presence_state", ok, "no presence_state within 3s")

	// 4/5 — broadcast to the other client, and the echo to the sender
	onB, onA := newWaiter(), newWaiter()
	chB.On("conf:hello", func(p any) { onB.deliver(p) })
	chA.On("conf:hello", func(p any) { onA.deliver(p) })

	if err := chA.Send("conf:hello", map[string]any{"n": 42}); err != nil {
		fail(4, "broadcast", err.Error())
	}

	gotB, okB := onB.wait(3 * time.Second)
	check(4, "broadcast reaches other client", okB && numField(gotB, "n") == 42, fmt.Sprint(gotB))

	gotA, okA := onA.wait(3 * time.Second)
	check(5, "broadcast echoes to sender", okA && numField(gotA, "n") == 42, fmt.Sprint(gotA))

	// 6/7 — floor granted and announced to everyone
	floorA, floorB := newWaiter(), newWaiter()
	chA.On("konet:floor", func(p any) { floorA.deliver(p) })
	chB.On("konet:floor", func(p any) { floorB.deliver(p) })

	holder, err := chA.AcquireFloor(ctx)
	check(6, "acquire floor", err == nil && holder != "", fmt.Sprint(err))

	annA, okAnnA := floorA.wait(3 * time.Second)
	annB, okAnnB := floorB.wait(3 * time.Second)
	check(7, "floor announced to both",
		okAnnA && okAnnB && strField(annA, "holder") == holder && strField(annB, "holder") == holder,
		fmt.Sprintf("A=%v B=%v", annA, annB))

	// 8 — second holder refused, and told who has it
	_, err = chB.AcquireFloor(ctx)
	check(8, "second holder refused", err != nil && contains(err.Error(), "floor_held"), fmt.Sprint(err))

	// 9/10 — binary reaches B, and must not echo to A
	payload := []byte{1, 2, 3, 250}
	binB := newWaiter()
	var binAReceived bool
	var binAMu sync.Mutex

	chB.OnBinary("audio", func(data []byte) {
		cp := append([]byte(nil), data...)
		binB.deliver(cp)
	})
	chA.OnBinary("audio", func(_ []byte) {
		binAMu.Lock()
		binAReceived = true
		binAMu.Unlock()
	})

	if err := chA.SendBinary("audio", payload); err != nil {
		fail(9, "binary frame round-trips", err.Error())
	}

	gotBin, okBin := binB.wait(3 * time.Second)
	check(9, "binary frame round-trips", okBin && sameBytes(gotBin, payload), fmt.Sprint(gotBin))

	time.Sleep(400 * time.Millisecond)
	binAMu.Lock()
	echoed := binAReceived
	binAMu.Unlock()
	check(10, "binary does not echo to sender", !echoed, "sender received its own audio")

	// 11 — a client without the floor is refused, and the channel survives it
	_ = chB.SendBinary("audio", payload)
	time.Sleep(300 * time.Millisecond)

	survive := newWaiter()
	chB.On("conf:after-refusal", func(p any) { survive.deliver(p) })
	_ = chA.Send("conf:after-refusal", map[string]any{"ok": true})
	_, okSurvive := survive.wait(3 * time.Second)
	check(11, "channel survives a refused binary frame", okSurvive, "no traffic after the refusal")

	// 12 — release, then B can take it
	if err := chA.ReleaseFloor(ctx); err != nil {
		fail(12, "floor is transferable", "release: "+err.Error())
	} else {
		newHolder, err := chB.AcquireFloor(ctx)
		check(12, "floor is transferable", err == nil && newHolder != "", fmt.Sprint(err))
		_ = chB.ReleaseFloor(ctx)
	}

	// 15 — a second socket of the *same* user shares the floor rather than being
	// refused. This is what made step 8 pass spuriously when both clients used
	// one token.
	same := konet.New(url, token, opts)
	if err := same.Connect(ctx); err != nil {
		fail(15, "the floor is per user, not per socket", err.Error())
	} else {
		chSame := same.Channel(room)
		sameCtx, cancelSame := context.WithTimeout(ctx, 5*time.Second)
		if err := chSame.Subscribe(sameCtx); err != nil {
			fail(15, "the floor is per user, not per socket", err.Error())
		} else {
			held, err1 := chA.AcquireFloor(ctx)
			alsoHeld, err2 := chSame.AcquireFloor(ctx)
			check(15, "the floor is per user, not per socket",
				err1 == nil && err2 == nil && held == alsoHeld,
				fmt.Sprintf("A=%q other socket=%q err=%v/%v", held, alsoHeld, err1, err2))
			_ = chA.ReleaseFloor(ctx)
		}
		cancelSame()
		same.Disconnect()
	}

	// 13 — a late joiner receives the replay buffer
	c := konet.New(url, token, opts)
	if err := c.Connect(ctx); err != nil {
		fail(13, "konet:history replay", err.Error())
	} else {
		defer c.Disconnect()
		chC := c.Channel(room)
		history := newWaiter()
		chC.On("konet:history", func(p any) { history.deliver(p) })

		joinCtx2, cancel2 := context.WithTimeout(ctx, 5*time.Second)
		defer cancel2()
		if err := chC.Subscribe(joinCtx2); err != nil {
			fail(13, "konet:history replay", err.Error())
		} else {
			h, okH := history.wait(4 * time.Second)
			check(13, "konet:history replay", okH && historyShapeOK(h), fmt.Sprint(h))
		}
	}

	// 14 — the channel is still usable at the end of all that
	final := newWaiter()
	chB.On("conf:final", func(p any) { final.deliver(p) })
	_ = chA.Send("conf:final", map[string]any{"done": true})
	_, okFinal := final.wait(3 * time.Second)
	check(14, "channel survives the whole scenario", okFinal, "no final message")

	finish()
}

func finish() {
	if failures == 0 {
		fmt.Println("OK go")
		os.Exit(0)
	}
	fmt.Printf("FAILED go (%d)\n", failures)
	os.Exit(1)
}

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func numField(v any, key string) int {
	m, ok := v.(map[string]any)
	if !ok {
		return -1
	}
	f, ok := m[key].(float64)
	if !ok {
		return -1
	}
	return int(f)
}

func strField(v any, key string) string {
	m, ok := v.(map[string]any)
	if !ok {
		return ""
	}
	s, _ := m[key].(string)
	return s
}

func sameBytes(v any, want []byte) bool {
	got, ok := v.([]byte)
	if !ok || len(got) != len(want) {
		return false
	}
	for i := range want {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}

// historyShapeOK asserts the replay payload shape, which no SDK's own tests
// cover in any language.
func historyShapeOK(v any) bool {
	m, ok := v.(map[string]any)
	if !ok {
		return false
	}
	messages, ok := m["messages"].([]any)
	if !ok || len(messages) == 0 {
		return false
	}
	for _, raw := range messages {
		entry, ok := raw.(map[string]any)
		if !ok {
			return false
		}
		if _, ok := entry["event"].(string); !ok {
			return false
		}
		if _, ok := entry["timestamp"].(string); !ok {
			return false
		}
		if _, present := entry["payload"]; !present {
			return false
		}
	}
	return true
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && (func() bool {
		for i := 0; i+len(needle) <= len(haystack); i++ {
			if haystack[i:i+len(needle)] == needle {
				return true
			}
		}
		return false
	})()
}
