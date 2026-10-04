package konet

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
)

type channelState int

const (
	channelIdle    channelState = iota
	channelJoining channelState = iota
	channelJoined  channelState = iota
	channelErrored channelState = iota
)

// BinaryMode is how binary frames are shared on a topic.
type BinaryMode string

const (
	// BinaryExclusive allows one sender at a time, arbitrated by the floor
	// (AcquireFloor). Half-duplex: push-to-talk, a radio net. The default.
	BinaryExclusive BinaryMode = "exclusive"
	// BinaryMultiplex lets every member send whenever it likes. There is no
	// floor at all. Full-duplex: a call.
	BinaryMultiplex BinaryMode = "multiplex"
)

// ChannelOption configures a channel at creation. See Client.Channel.
type ChannelOption func(*Channel)

// WithBinaryMode asks for a binary mode at join. The mode belongs to the
// topic, not to one member: a join asking for a different mode from the
// members already there is refused with binary_mode_mismatch, so every member
// of a topic must ask for the same one.
func WithBinaryMode(mode BinaryMode) ChannelOption {
	return func(c *Channel) { c.requestedMode = mode }
}

// ErrSocketClosed reports a request whose socket went away before the server
// replied. Distinct from a refusal: nothing is known about whether the server
// saw it.
var ErrSocketClosed = errors.New("konet: socket fermée avant la réponse")

type phxFrame struct {
	JoinRef *string
	Ref     *string
	Topic   string
	Event   string
	Payload interface{}
}

func (f phxFrame) toWire() []interface{} {
	return []interface{}{f.JoinRef, f.Ref, f.Topic, f.Event, f.Payload}
}

// EventHandler handles an incoming event payload.
type EventHandler func(payload interface{})

// BinaryHandler handles an incoming binary frame. The slice is only valid for
// the duration of the call — copy it to keep it.
type BinaryHandler func(data []byte)

// BinarySenderHandler is a BinaryHandler that also receives who sent the
// frame. sender is the member's user id, stamped by the server, on a
// BinaryMultiplex topic; it is "" on a BinaryExclusive one, where the floor
// holder is the sender.
type BinarySenderHandler func(data []byte, sender string)

// Handlers are stored with an identity of their own rather than compared by
// value: Go gives no usable equality for funcs, and comparing code pointers
// (fmt.Sprintf("%p", h)) matches distinct closures that share a body. An
// explicit id makes the unsubscribe returned by On/OnBinary exact, and keeping
// them in a slice preserves registration order.
type eventSub struct {
	id uint64
	fn EventHandler
}

type binarySub struct {
	id   uint64
	fn   BinaryHandler
	from BinarySenderHandler
}

// Channel represents a subscription to a Konet channel topic.
type Channel struct {
	topic string

	mu       sync.RWMutex
	state    channelState
	handlers map[string][]eventSub
	replies  map[string]chan interface{}
	joinRef  *string
	// wantsJoin records whether the application wants this channel joined. It
	// survives socket drops, so a reconnect knows what to restore, and is
	// cleared only by Unsubscribe — a channel the caller deliberately left is
	// never silently re-joined.
	wantsJoin  bool
	handlerSeq uint64

	// requestedMode is sent on every join, reconnects included: the server
	// forgets a topic's mode once it empties, so a rejoin without it would come
	// back as whatever the server defaults to. Empty means the server default.
	requestedMode BinaryMode
	// confirmedMode is what the server said at the last successful join.
	confirmedMode BinaryMode

	sendFn       func(phxFrame) error
	sendBinaryFn func(joinRef, ref, topic, event string, data []byte) error
	nextRef      func() string

	// binaryHandlers are separate from handlers because a binary event
	// delivers []byte, not a decoded payload, and mixing the two would force
	// every handler to type-switch on something it already knows.
	binaryHandlers map[string][]binarySub
}

func newChannel(
	topic string,
	sendFn func(phxFrame) error,
	sendBinaryFn func(joinRef, ref, topic, event string, data []byte) error,
	nextRef func() string,
	opts ...ChannelOption,
) *Channel {
	c := &Channel{
		topic:          topic,
		state:          channelIdle,
		handlers:       make(map[string][]eventSub),
		binaryHandlers: make(map[string][]binarySub),
		replies:        make(map[string]chan interface{}),
		sendFn:         sendFn,
		sendBinaryFn:   sendBinaryFn,
		nextRef:        nextRef,
	}
	for _, opt := range opts {
		opt(c)
	}
	return c
}

// BinaryMode returns the mode the server confirmed for this topic, or "" until
// the channel is joined. A server older than the mode reports nothing and is
// read as BinaryExclusive, which is what it always did.
func (c *Channel) BinaryMode() BinaryMode {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.confirmedMode
}

func (c *Channel) joinPayload() map[string]interface{} {
	if c.requestedMode == "" {
		return map[string]interface{}{}
	}
	return map[string]interface{}{"binary_mode": string(c.requestedMode)}
}

// Topic returns the channel's topic.
func (c *Channel) Topic() string { return c.topic }

// Joined reports whether the server has confirmed this channel's join on the
// current socket.
func (c *Channel) Joined() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.state == channelJoined
}

// Subscribe joins the channel. Blocks until the server confirms the join.
func (c *Channel) Subscribe(ctx context.Context) error {
	c.mu.Lock()
	c.wantsJoin = true
	if c.state == channelJoined || c.state == channelJoining {
		c.mu.Unlock()
		return nil
	}
	c.state = channelJoining
	ref := c.nextRef()
	c.joinRef = &ref
	replyCh := make(chan interface{}, 1)
	c.replies[ref] = replyCh
	c.mu.Unlock()

	if err := c.sendFn(phxFrame{
		JoinRef: &ref,
		Ref:     &ref,
		Topic:   c.topic,
		Event:   "phx_join",
		Payload: c.joinPayload(),
	}); err != nil {
		c.mu.Lock()
		c.state = channelErrored
		delete(c.replies, ref)
		c.mu.Unlock()
		return fmt.Errorf("subscribe: send: %w", err)
	}

	select {
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.replies, ref)
		if c.state == channelJoining {
			c.state = channelIdle
		}
		c.mu.Unlock()
		return ctx.Err()

	case reply, ok := <-replyCh:
		if !ok {
			// socketClosed closed the channel: the socket went away before the
			// server answered.
			return ErrSocketClosed
		}

		m, isMap := reply.(map[string]interface{})
		if !isMap {
			c.setState(channelErrored)
			return fmt.Errorf("subscribe: unexpected reply type")
		}
		if m["status"] != "ok" {
			// wantsJoin stays set: a rejection is often a stale or expired
			// token, and the next reconnect should try again with whatever
			// token the client holds by then.
			c.setState(channelErrored)
			return fmt.Errorf("subscribe: server error: %v", m["response"])
		}

		confirmed := BinaryExclusive
		if resp, ok := m["response"].(map[string]interface{}); ok {
			if mode, ok := resp["binary_mode"].(string); ok && mode != "" {
				confirmed = BinaryMode(mode)
			}
		}

		c.mu.Lock()
		// A reply from a join that a reconnect already superseded.
		if c.joinRef != nil && *c.joinRef == ref {
			c.state = channelJoined
			c.confirmedMode = confirmed
		}
		c.mu.Unlock()
		return nil
	}
}

// Unsubscribe leaves the channel.
func (c *Channel) Unsubscribe() error {
	c.mu.Lock()
	c.wantsJoin = false
	if c.state != channelJoined {
		c.state = channelIdle
		c.joinRef = nil
		c.mu.Unlock()
		return nil
	}
	c.state = channelIdle
	ref := c.nextRef()
	jr := c.joinRef
	c.joinRef = nil
	c.mu.Unlock()

	return c.sendFn(phxFrame{
		JoinRef: jr,
		Ref:     &ref,
		Topic:   c.topic,
		Event:   "phx_leave",
		Payload: map[string]interface{}{},
	})
}

// On registers a handler for an event. Returns a function that removes it.
func (c *Channel) On(event string, handler EventHandler) func() {
	c.mu.Lock()
	c.handlerSeq++
	id := c.handlerSeq
	c.handlers[event] = append(c.handlers[event], eventSub{id: id, fn: handler})
	c.mu.Unlock()

	return func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		list := c.handlers[event]
		for i, sub := range list {
			if sub.id == id {
				c.handlers[event] = append(list[:i:i], list[i+1:]...)
				return
			}
		}
	}
}

// Send broadcasts an event to all channel subscribers via the server.
func (c *Channel) Send(event string, payload interface{}) error {
	c.mu.RLock()
	state := c.state
	jr := c.joinRef
	c.mu.RUnlock()

	if state != channelJoined {
		return fmt.Errorf("channel %s is not joined", c.topic)
	}

	ref := c.nextRef()
	return c.sendFn(phxFrame{
		JoinRef: jr,
		Ref:     &ref,
		Topic:   c.topic,
		Event:   "broadcast",
		Payload: map[string]interface{}{"event": event, "payload": payload},
	})
}

// SendBinary sends a binary frame — audio, or anything else at a media rate.
//
// Three things differ from Send, and all follow from the rate: Phoenix frames
// it natively instead of base64 inside JSON, the server never acknowledges it,
// and in BinaryExclusive mode it is refused unless this client holds the
// channel's floor — take it with AcquireFloor first. In BinaryMultiplex mode
// any member may send at any time, and receivers learn who sent each frame
// through OnBinaryFrom.
//
// data is copied into the frame, so the caller may reuse its buffer at once.
func (c *Channel) SendBinary(event string, data []byte) error {
	c.mu.RLock()
	state := c.state
	jr := c.joinRef
	c.mu.RUnlock()

	if state != channelJoined {
		return fmt.Errorf("channel %s is not joined", c.topic)
	}

	joinRef := ""
	if jr != nil {
		joinRef = *jr
	}

	// Not tracked like Send: at fifty frames a second, a reply channel per
	// frame would cost more than the frames do.
	return c.sendBinaryFn(joinRef, c.nextRef(), c.topic, event, data)
}

// OnBinary registers a handler for binary frames on this event. Returns a
// function that removes it.
func (c *Channel) OnBinary(event string, handler BinaryHandler) func() {
	return c.addBinarySub(event, binarySub{fn: handler})
}

// OnBinaryFrom registers a handler for binary frames on this event that also
// receives the sender. On a BinaryMultiplex topic, where several members send
// at once, the sender is the only way to tell the streams apart — one decoder
// per sender, for instance. Returns a function that removes it.
func (c *Channel) OnBinaryFrom(event string, handler BinarySenderHandler) func() {
	return c.addBinarySub(event, binarySub{from: handler})
}

func (c *Channel) addBinarySub(event string, sub binarySub) func() {
	c.mu.Lock()
	c.handlerSeq++
	id := c.handlerSeq
	sub.id = id
	c.binaryHandlers[event] = append(c.binaryHandlers[event], sub)
	c.mu.Unlock()

	return func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		list := c.binaryHandlers[event]
		for i, sub := range list {
			if sub.id == id {
				c.binaryHandlers[event] = append(list[:i:i], list[i+1:]...)
				return
			}
		}
	}
}

// AcquireFloor claims the right to send on this channel. At most one member
// holds it at a time, which is how half-duplex media — push-to-talk — is
// arbitrated. Returns the holder, which is this client on success; an error
// names whoever already holds it. Only in BinaryExclusive mode: a
// BinaryMultiplex topic has no floor, and the server refuses with
// floor_disabled.
func (c *Channel) AcquireFloor(ctx context.Context) (string, error) {
	response, err := c.request(ctx, "konet:floor_acquire")
	if err != nil {
		return "", err
	}

	var reply struct {
		Holder string `json:"holder"`
	}
	if err := MarshalPayload(response, &reply); err != nil {
		return "", err
	}
	return reply.Holder, nil
}

// ReleaseFloor gives the floor back. Only the holder may.
func (c *Channel) ReleaseFloor(ctx context.Context) error {
	_, err := c.request(ctx, "konet:floor_release")
	return err
}

// request is a push that expects a reply, unlike the fire-and-forget Send.
func (c *Channel) request(ctx context.Context, event string) (interface{}, error) {
	c.mu.RLock()
	state := c.state
	jr := c.joinRef
	c.mu.RUnlock()

	if state != channelJoined {
		return nil, fmt.Errorf("channel %s is not joined", c.topic)
	}

	ref := c.nextRef()
	replies := make(chan interface{}, 1)

	c.mu.Lock()
	c.replies[ref] = replies
	c.mu.Unlock()

	if err := c.sendFn(phxFrame{
		JoinRef: jr,
		Ref:     &ref,
		Topic:   c.topic,
		Event:   event,
		Payload: map[string]interface{}{},
	}); err != nil {
		c.mu.Lock()
		delete(c.replies, ref)
		c.mu.Unlock()
		return nil, err
	}

	select {
	case payload, ok := <-replies:
		if !ok {
			return nil, ErrSocketClosed
		}

		var reply struct {
			Status   string      `json:"status"`
			Response interface{} `json:"response"`
		}
		if err := MarshalPayload(payload, &reply); err != nil {
			return nil, err
		}
		if reply.Status != "ok" {
			var refusal struct {
				Reason string `json:"reason"`
				Holder string `json:"holder"`
			}
			_ = MarshalPayload(reply.Response, &refusal)
			if refusal.Holder != "" {
				return nil, fmt.Errorf("konet: %s (détenue par %s)", refusal.Reason, refusal.Holder)
			}
			return nil, fmt.Errorf("konet: %s refusé (%s)", event, refusal.Reason)
		}
		return reply.Response, nil

	case <-ctx.Done():
		c.mu.Lock()
		delete(c.replies, ref)
		c.mu.Unlock()
		return nil, ctx.Err()
	}
}

// ── Reconnection hooks, called by Client ────────────────────────────────────

// socketClosed marks the channel as no longer joined, because the socket that
// carried the join is gone. Anything waiting on a reply is released: the server
// will never answer on a socket that no longer exists.
func (c *Channel) socketClosed() {
	c.mu.Lock()
	if c.state == channelJoined || c.state == channelJoining {
		c.state = channelIdle
	}
	c.joinRef = nil
	c.confirmedMode = ""
	replies := c.replies
	c.replies = make(map[string]chan interface{})
	c.mu.Unlock()

	for _, ch := range replies {
		close(ch)
	}
}

// rejoin restores a join the server lost, unless the caller deliberately left.
func (c *Channel) rejoin(ctx context.Context) error {
	c.mu.RLock()
	wants := c.wantsJoin
	state := c.state
	c.mu.RUnlock()

	if !wants || state == channelJoined || state == channelJoining {
		return nil
	}
	return c.Subscribe(ctx)
}

func (c *Channel) setState(s channelState) {
	c.mu.Lock()
	c.state = s
	c.mu.Unlock()
}

// ── Inbound dispatch ────────────────────────────────────────────────────────

// receiveBinary dispatches an incoming binary frame.
func (c *Channel) receiveBinary(event string, data []byte) {
	c.mu.RLock()
	subs := append([]binarySub{}, c.binaryHandlers[event]...)
	multiplex := c.confirmedMode == BinaryMultiplex
	c.mu.RUnlock()

	// Several members send at once on a multiplex topic, so the server puts the
	// sender in front of every frame. Keyed on the *confirmed* mode: a server
	// older than modes accepts the join, stays exclusive, and stamps nothing.
	sender := ""
	if multiplex {
		var err error
		if sender, data, err = splitSender(data); err != nil {
			return
		}
	}

	// Synchronous, unlike receive: audio frames must reach the play-out buffer
	// in the order they arrived, and one goroutine per frame would not promise
	// that.
	for _, sub := range subs {
		if sub.from != nil {
			sub.from(data, sender)
		} else {
			sub.fn(data)
		}
	}
}

func (c *Channel) receive(frame phxFrame) {
	switch frame.Event {
	case "phx_reply":
		c.mu.Lock()
		ref := ""
		if frame.Ref != nil {
			ref = *frame.Ref
		}
		ch := c.replies[ref]
		delete(c.replies, ref)
		c.mu.Unlock()
		if ch != nil {
			ch <- frame.Payload
		}

	default:
		if frame.Event == "phx_error" {
			c.setState(channelErrored)
		} else if frame.Event == "phx_close" {
			c.setState(channelIdle)
		}

		c.mu.RLock()
		subs := append([]eventSub{}, c.handlers[frame.Event]...)
		c.mu.RUnlock()
		for _, sub := range subs {
			go sub.fn(frame.Payload)
		}
	}
}

// MarshalPayload decodes the raw payload into a typed struct.
func MarshalPayload(raw interface{}, target interface{}) error {
	data, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, target)
}
