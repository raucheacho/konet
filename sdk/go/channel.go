package konet

import (
	"context"
	"encoding/json"
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

// Channel represents a subscription to a Konet channel topic.
type Channel struct {
	topic string
	state channelState

	mu       sync.RWMutex
	handlers map[string][]EventHandler
	replies  map[string]chan interface{}

	sendFn       func(phxFrame) error
	sendBinaryFn func(joinRef, ref, topic, event string, data []byte) error
	nextRef      func() string
	joinRef      *string

	// binaryHandlers are separate from handlers because a binary event
	// delivers []byte, not a decoded payload, and mixing the two would force
	// every handler to type-switch on something it already knows.
	binaryHandlers map[string][]BinaryHandler
}

func newChannel(
	topic string,
	sendFn func(phxFrame) error,
	sendBinaryFn func(joinRef, ref, topic, event string, data []byte) error,
	nextRef func() string,
) *Channel {
	return &Channel{
		topic:          topic,
		state:          channelIdle,
		handlers:       make(map[string][]EventHandler),
		binaryHandlers: make(map[string][]BinaryHandler),
		replies:        make(map[string]chan interface{}),
		sendFn:         sendFn,
		sendBinaryFn:   sendBinaryFn,
		nextRef:        nextRef,
	}
}

// Subscribe joins the channel. Blocks until the server confirms the join.
func (c *Channel) Subscribe(ctx context.Context) error {
	c.mu.Lock()
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
		Payload: map[string]interface{}{},
	}); err != nil {
		c.mu.Lock()
		c.state = channelErrored
		delete(c.replies, ref)
		c.mu.Unlock()
		return fmt.Errorf("subscribe: send: %w", err)
	}

	select {
	case <-ctx.Done():
		return ctx.Err()
	case reply := <-replyCh:
		m, ok := reply.(map[string]interface{})
		if !ok {
			return fmt.Errorf("subscribe: unexpected reply type")
		}
		if m["status"] != "ok" {
			c.mu.Lock()
			c.state = channelErrored
			c.mu.Unlock()
			return fmt.Errorf("subscribe: server error: %v", m["response"])
		}
		c.mu.Lock()
		c.state = channelJoined
		c.mu.Unlock()
		return nil
	}
}

// Unsubscribe leaves the channel.
func (c *Channel) Unsubscribe() error {
	c.mu.Lock()
	if c.state != channelJoined {
		c.mu.Unlock()
		return nil
	}
	c.state = channelIdle
	ref := c.nextRef()
	jr := c.joinRef
	c.mu.Unlock()

	return c.sendFn(phxFrame{
		JoinRef: jr,
		Ref:     &ref,
		Topic:   c.topic,
		Event:   "phx_leave",
		Payload: map[string]interface{}{},
	})
}

// On registers a handler for an event. Returns an unsubscribe function.
func (c *Channel) On(event string, handler EventHandler) func() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.handlers[event] = append(c.handlers[event], handler)

	return func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		list := c.handlers[event]
		updated := make([]EventHandler, 0, len(list))
		for _, h := range list {
			if fmt.Sprintf("%p", h) != fmt.Sprintf("%p", handler) {
				updated = append(updated, h)
			}
		}
		c.handlers[event] = updated
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
// and it is refused unless this client holds the channel's floor. Take the
// floor with AcquireFloor first.
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
	c.mu.Lock()
	defer c.mu.Unlock()

	c.binaryHandlers[event] = append(c.binaryHandlers[event], handler)
	index := len(c.binaryHandlers[event]) - 1

	return func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		list := c.binaryHandlers[event]
		if index < len(list) {
			c.binaryHandlers[event] = append(list[:index], list[index+1:]...)
		}
	}
}

// AcquireFloor claims the right to send on this channel. At most one member
// holds it at a time, which is how half-duplex media — push-to-talk — is
// arbitrated. Returns the holder, which is this client on success; an error
// names whoever already holds it.
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
	case payload := <-replies:
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

// receiveBinary dispatches an incoming binary frame.
func (c *Channel) receiveBinary(event string, data []byte) {
	c.mu.RLock()
	handlers := append([]BinaryHandler{}, c.binaryHandlers[event]...)
	c.mu.RUnlock()

	// Synchronous, unlike receive: audio frames must reach the play-out buffer
	// in the order they arrived, and one goroutine per frame would not promise
	// that.
	for _, h := range handlers {
		h(data)
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
		c.mu.RLock()
		handlers := append([]EventHandler{}, c.handlers[frame.Event]...)
		c.mu.RUnlock()
		for _, h := range handlers {
			go h(frame.Payload)
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
