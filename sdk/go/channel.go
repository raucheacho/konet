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

// Channel represents a subscription to a Konet channel topic.
type Channel struct {
	topic string
	state channelState

	mu       sync.RWMutex
	handlers map[string][]EventHandler
	replies  map[string]chan interface{}

	sendFn  func(phxFrame) error
	nextRef func() string
	joinRef *string
}

func newChannel(topic string, sendFn func(phxFrame) error, nextRef func() string) *Channel {
	return &Channel{
		topic:    topic,
		state:    channelIdle,
		handlers: make(map[string][]EventHandler),
		replies:  make(map[string]chan interface{}),
		sendFn:   sendFn,
		nextRef:  nextRef,
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
