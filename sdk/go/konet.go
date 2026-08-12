// Package konet provides a Go client for the Konet realtime server.
package konet

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// Client connects to a Konet server and manages channels.
type Client struct {
	url   string
	token string

	mu       sync.RWMutex
	conn     *websocket.Conn
	channels map[string]*Channel
	// started guards the read and heartbeat loops: they are spawned by the
	// first Connect and live across reconnects. Spawning them again on every
	// reconnect leaked a heartbeat goroutine per attempt, since only Disconnect
	// closes done.
	started bool
	// pendingHeartbeat is the ref of the probe waiting for a reply, or "".
	pendingHeartbeat string

	refCounter atomic.Uint64
	done       chan struct{}
	closeOnce  sync.Once
	opts       ClientOptions
}

// ClientOptions configures the client behavior.
type ClientOptions struct {
	HeartbeatInterval time.Duration
	ReconnectDelay    time.Duration
	MaxReconnectTries int
	HTTPHeader        http.Header
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
	if o.HeartbeatInterval <= 0 {
		o.HeartbeatInterval = defaultOptions().HeartbeatInterval
	}
	if o.ReconnectDelay <= 0 {
		o.ReconnectDelay = defaultOptions().ReconnectDelay
	}
	return &Client{
		url:      url,
		token:    token,
		channels: make(map[string]*Channel),
		done:     make(chan struct{}),
		opts:     o,
	}
}

func (c *Client) websocketURL() string {
	// Phoenix mounts the actual websocket transport at "<socket path>/websocket",
	// not at the socket path itself (e.g. "/socket" -> "/socket/websocket").
	base := strings.TrimSuffix(c.url, "/")
	return fmt.Sprintf("%s/websocket?token=%s&vsn=2.0.0", base, url.QueryEscape(c.token))
}

func (c *Client) dial(ctx context.Context) (*websocket.Conn, error) {
	conn, _, err := websocket.Dial(ctx, c.websocketURL(), &websocket.DialOptions{
		HTTPHeader: c.opts.HTTPHeader,
	})
	if err != nil {
		return nil, fmt.Errorf("konet: connect: %w", err)
	}
	return conn, nil
}

// Connect opens the WebSocket connection and starts the read loop.
func (c *Client) Connect(ctx context.Context) error {
	conn, err := c.dial(ctx)
	if err != nil {
		return err
	}

	c.mu.Lock()
	c.conn = conn
	c.pendingHeartbeat = ""
	spawn := !c.started
	c.started = true
	c.mu.Unlock()

	if spawn {
		go c.readLoop(ctx)
		go c.heartbeatLoop(ctx)
	}
	return nil
}

// Disconnect closes the connection gracefully.
func (c *Client) Disconnect() {
	c.closeOnce.Do(func() { close(c.done) })

	c.mu.Lock()
	conn := c.conn
	c.conn = nil
	c.started = false
	channels := c.channelList()
	c.mu.Unlock()

	for _, ch := range channels {
		ch.socketClosed()
	}
	if conn != nil {
		conn.Close(websocket.StatusNormalClosure, "client disconnect")
	}
}

// Connected reports whether a socket is currently open.
func (c *Client) Connected() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.conn != nil
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

// channelList snapshots the channels. Callers must hold at least a read lock,
// except where noted.
func (c *Client) channelList() []*Channel {
	out := make([]*Channel, 0, len(c.channels))
	for _, ch := range c.channels {
		out = append(out, ch)
	}
	return out
}

func (c *Client) snapshotChannels() []*Channel {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.channelList()
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
			// Only reachable if a reconnect left us without a socket.
			// reconnect owns the backoff; never spin here.
			if !c.reconnect(ctx) {
				return
			}
			continue
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
			}
			if !c.reconnect(ctx) {
				return
			}
			continue
		}

		if messageType == websocket.MessageBinary {
			c.handleBinary(message)
			continue
		}

		c.handleText(message)
	}
}

func (c *Client) handleText(message []byte) {
	var raw []json.RawMessage
	if err := json.Unmarshal(message, &raw); err != nil {
		return
	}

	if len(raw) != 5 {
		return
	}

	var joinRef, ref, topic, event *string
	json.Unmarshal(raw[0], &joinRef)
	json.Unmarshal(raw[1], &ref)
	json.Unmarshal(raw[2], &topic)
	json.Unmarshal(raw[3], &event)

	if topic == nil || event == nil {
		return
	}

	if *topic == "phoenix" {
		// The heartbeat reply is this client's only proof the server is still
		// there — it is the liveness signal, not noise to discard.
		if ref != nil {
			c.mu.Lock()
			if c.pendingHeartbeat == *ref {
				c.pendingHeartbeat = ""
			}
			c.mu.Unlock()
		}
		return
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

	c.mu.RLock()
	ch := c.channels[*topic]
	c.mu.RUnlock()

	if ch != nil {
		ch.receive(frame)
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
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.mu.Lock()
			conn := c.conn
			outstanding := c.pendingHeartbeat
			var ref string
			if conn != nil && outstanding == "" {
				ref = c.nextRef()
				c.pendingHeartbeat = ref
			}
			c.mu.Unlock()

			if conn == nil {
				continue
			}

			if outstanding != "" {
				// The previous probe was never answered: whatever the local
				// socket claims, nothing is listening on the other end.
				// Closing it makes readLoop's Read fail, so reconnection stays
				// in one place instead of racing this loop.
				conn.Close(websocket.StatusPolicyViolation, "heartbeat timeout")
				continue
			}

			if err := c.send(phxFrame{Topic: "phoenix", Event: "heartbeat", Ref: &ref}); err != nil {
				c.mu.Lock()
				if c.pendingHeartbeat == ref {
					c.pendingHeartbeat = ""
				}
				c.mu.Unlock()
			}
		}
	}
}

// reconnect re-opens the socket with exponential backoff and restores the
// joins. It reports false once MaxReconnectTries is exhausted, which ends the
// read loop rather than leaving it awake with nothing to read.
func (c *Client) reconnect(ctx context.Context) bool {
	// Every server-side join died with the socket. Marking the channels makes
	// Send fail loudly instead of writing into a dead topic, and tells the
	// rejoin which channels to restore.
	for _, ch := range c.snapshotChannels() {
		ch.socketClosed()
	}

	c.mu.Lock()
	old := c.conn
	c.conn = nil
	c.pendingHeartbeat = ""
	c.mu.Unlock()

	// Dropping the reference is not enough: the websocket library keeps a
	// goroutine per connection until it is closed, so an abandoned socket leaks
	// one per reconnect.
	if old != nil {
		old.CloseNow()
	}

	for attempt := 0; attempt < c.opts.MaxReconnectTries; attempt++ {
		delay := time.Duration(float64(c.opts.ReconnectDelay) * math.Pow(2, float64(attempt)))
		if delay > 30*time.Second {
			delay = 30 * time.Second
		}

		timer := time.NewTimer(delay)
		select {
		case <-c.done:
			timer.Stop()
			return false
		case <-ctx.Done():
			timer.Stop()
			return false
		case <-timer.C:
		}

		conn, err := c.dial(ctx)
		if err != nil {
			continue
		}

		c.mu.Lock()
		c.conn = conn
		c.mu.Unlock()

		// The server knows nothing about the topics this client had joined on
		// the previous socket. Re-issue phx_join — but from a goroutine, not
		// inline: a join blocks on its reply, and that reply can only arrive
		// through the read loop that is calling us.
		go c.rejoinChannels(ctx)
		return true
	}

	return false
}

func (c *Client) rejoinChannels(ctx context.Context) {
	for _, ch := range c.snapshotChannels() {
		// One channel failing to re-join (an expired token, a room that now
		// refuses this client) must not stop the others.
		_ = ch.rejoin(ctx)
	}
}
