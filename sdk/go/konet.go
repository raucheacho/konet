// Package konet provides a Go client for the Konet realtime server.
package konet

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"nhooyr.io/websocket"
	"nhooyr.io/websocket/wsjson"
)

// Client connects to a Konet server and manages channels.
type Client struct {
	url   string
	token string

	mu       sync.RWMutex
	conn     *websocket.Conn
	channels map[string]*Channel

	refCounter atomic.Uint64
	done       chan struct{}
	opts       ClientOptions
}

// ClientOptions configures the client behavior.
type ClientOptions struct {
	HeartbeatInterval  time.Duration
	ReconnectDelay     time.Duration
	MaxReconnectTries  int
	HTTPHeader         http.Header
}

func defaultOptions() ClientOptions {
	return ClientOptions{
		HeartbeatInterval: 30 * time.Second,
		ReconnectDelay:    time.Second,
		MaxReconnectTries: 10,
	}
}

// New creates a new Konet client. Call Connect to establish the WebSocket connection.
func New(url, token string, opts ...ClientOptions) *Client {
	o := defaultOptions()
	if len(opts) > 0 {
		o = opts[0]
	}
	return &Client{
		url:      url,
		token:    token,
		channels: make(map[string]*Channel),
		done:     make(chan struct{}),
		opts:     o,
	}
}

// Connect opens the WebSocket connection and starts the read loop.
func (c *Client) Connect(ctx context.Context) error {
	// Phoenix mounts the actual websocket transport at "<socket path>/websocket",
	// not at the socket path itself (e.g. "/socket" -> "/socket/websocket").
	base := strings.TrimSuffix(c.url, "/")
	wsURL := fmt.Sprintf("%s/websocket?token=%s&vsn=2.0.0", base, c.token)

	conn, _, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{
		HTTPHeader: c.opts.HTTPHeader,
	})
	if err != nil {
		return fmt.Errorf("konet: connect: %w", err)
	}

	c.mu.Lock()
	c.conn = conn
	c.mu.Unlock()

	go c.readLoop(ctx)
	go c.heartbeatLoop(ctx)
	return nil
}

// Disconnect closes the connection gracefully.
func (c *Client) Disconnect() {
	select {
	case <-c.done:
	default:
		close(c.done)
	}
	c.mu.Lock()
	if c.conn != nil {
		c.conn.Close(websocket.StatusNormalClosure, "client disconnect")
		c.conn = nil
	}
	c.mu.Unlock()
}

// Channel returns (or creates) a channel for the given topic.
func (c *Client) Channel(topic string) *Channel {
	c.mu.Lock()
	defer c.mu.Unlock()

	if ch, ok := c.channels[topic]; ok {
		return ch
	}

	ch := newChannel(topic, c.send, c.sendBinary, c.nextRef)
	c.channels[topic] = ch
	return ch
}

func (c *Client) send(frame phxFrame) error {
	c.mu.RLock()
	conn := c.conn
	c.mu.RUnlock()

	if conn == nil {
		return fmt.Errorf("konet: not connected")
	}
	return wsjson.Write(context.Background(), conn, frame.toWire())
}

// sendBinary writes a binary push.
//
// Never buffered while the socket is down, unlike text: replaying audio
// recorded seconds ago into a live channel would be worse than losing it — by
// the time it arrives, the moment has passed.
func (c *Client) sendBinary(joinRef, ref, topic, event string, data []byte) error {
	c.mu.RLock()
	conn := c.conn
	c.mu.RUnlock()

	if conn == nil {
		return fmt.Errorf("konet: not connected")
	}

	frame, err := encodeBinaryPush(joinRef, ref, topic, event, data)
	if err != nil {
		return err
	}
	return conn.Write(context.Background(), websocket.MessageBinary, frame)
}

func (c *Client) nextRef() string {
	return fmt.Sprintf("%d", c.refCounter.Add(1))
}

func (c *Client) readLoop(ctx context.Context) {
	for {
		select {
		case <-c.done:
			return
		default:
		}

		c.mu.RLock()
		conn := c.conn
		c.mu.RUnlock()

		if conn == nil {
			return
		}

		// conn.Read rather than wsjson.Read: the opcode is what tells text
		// from binary, and wsjson would consume it and try to parse audio as
		// JSON.
		messageType, message, err := conn.Read(ctx)
		if err != nil {
			select {
			case <-c.done:
				return
			default:
				c.reconnect(ctx)
				return
			}
		}

		if messageType == websocket.MessageBinary {
			c.handleBinary(message)
			continue
		}

		var raw []json.RawMessage
		if err := json.Unmarshal(message, &raw); err != nil {
			continue
		}

		if len(raw) != 5 {
			continue
		}

		var joinRef, ref, topic, event *string
		json.Unmarshal(raw[0], &joinRef)
		json.Unmarshal(raw[1], &ref)
		json.Unmarshal(raw[2], &topic)
		json.Unmarshal(raw[3], &event)

		if topic == nil || event == nil {
			continue
		}

		var payload interface{}
		json.Unmarshal(raw[4], &payload)

		frame := phxFrame{
			JoinRef: joinRef,
			Ref:     ref,
			Topic:   *topic,
			Event:   *event,
			Payload: payload,
		}

		if *topic == "phoenix" {
			continue
		}

		c.mu.RLock()
		ch := c.channels[*topic]
		c.mu.RUnlock()

		if ch != nil {
			ch.receive(frame)
		}
	}
}

// handleBinary routes a binary frame to its channel. A malformed frame is
// dropped rather than fatal: it must not take down the socket that carries
// every other channel.
func (c *Client) handleBinary(message []byte) {
	frame, err := decodeServerBinaryFrame(message)
	if err != nil {
		return
	}

	// A binary reply means the server refused the frame. Nothing waits on one,
	// since SendBinary does not track refs.
	if frame.Kind != binaryBroadcast && frame.Kind != binaryPush {
		return
	}

	c.mu.RLock()
	ch := c.channels[frame.Topic]
	c.mu.RUnlock()

	if ch != nil {
		ch.receiveBinary(frame.Event, frame.Data)
	}
}

func (c *Client) heartbeatLoop(ctx context.Context) {
	ticker := time.NewTicker(c.opts.HeartbeatInterval)
	defer ticker.Stop()

	for {
		select {
		case <-c.done:
			return
		case <-ticker.C:
			c.send(phxFrame{
				Topic: "phoenix",
				Event: "heartbeat",
				Ref:   &[]string{c.nextRef()}[0],
			})
		}
	}
}

func (c *Client) reconnect(ctx context.Context) {
	for attempt := 0; attempt < c.opts.MaxReconnectTries; attempt++ {
		select {
		case <-c.done:
			return
		default:
		}

		delay := time.Duration(float64(c.opts.ReconnectDelay) * math.Pow(2, float64(attempt)))
		if delay > 30*time.Second {
			delay = 30 * time.Second
		}
		time.Sleep(delay)

		if err := c.Connect(ctx); err == nil {
			// Rejoin all channels
			c.mu.RLock()
			channels := make([]*Channel, 0, len(c.channels))
			for _, ch := range c.channels {
				channels = append(channels, ch)
			}
			c.mu.RUnlock()

			for _, ch := range channels {
				if ch.state == channelJoined {
					ch.state = channelIdle
					ch.Subscribe(ctx)
				}
			}
			return
		}
	}
}
