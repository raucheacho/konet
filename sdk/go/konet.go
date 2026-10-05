// Package konet provides a Go client for the Konet realtime server.
package konet

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"math/rand"
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
	// stop cancels the context the read and heartbeat loops run on. That
	// context belongs to the client, not to the caller of Connect: see Connect.
	stop      context.CancelFunc
	done      chan struct{}
	closeOnce sync.Once
	opts      ClientOptions
}

// ClientOptions configures the client behavior.
type ClientOptions struct {
	HeartbeatInterval time.Duration
	ReconnectDelay    time.Duration
	MaxReconnectTries int
	HTTPHeader        http.Header
	// OnStatus, when set, is called on every change of connection status — to
	// show "reconnecting…", or to learn that the client gave up. It runs on the
	// client's own goroutine: return quickly, and do not call Connect or
	// Disconnect from it.
	OnStatus func(Status)
}

// StatusState is what the connection is doing.
type StatusState string

const (
	// StatusConnecting: a socket is being opened.
	StatusConnecting StatusState = "connecting"
	// StatusConnected: it is open; channels are being re-joined.
	StatusConnected StatusState = "connected"
	// StatusReconnecting: it was lost, and attempt Attempt starts after Delay.
	StatusReconnecting StatusState = "reconnecting"
	// StatusDisconnected: Disconnect was called.
	StatusDisconnected StatusState = "disconnected"
	// StatusFailed: MaxReconnectTries were used up and the client stopped.
	StatusFailed StatusState = "failed"
)

// Status is reported to ClientOptions.OnStatus. Attempt and Delay are only set
// for StatusReconnecting.
type Status struct {
	State   StatusState
	Attempt int
	Delay   time.Duration
}

func (c *Client) emitStatus(s Status) {
	if c.opts.OnStatus == nil {
		return
	}
	// A failing UI callback must not take the connection logic with it.
	defer func() { _ = recover() }()
	c.opts.OnStatus(s)
}

// maxReconnectDelay is the ceiling on one reconnect delay.
const maxReconnectDelay = 30 * time.Second

// reconnectDelay is exponential backoff with "equal jitter": half the step is
// fixed, half is random. Without the random half, every client dropped by a
// server restart came back at the same 1 s, 2 s, 4 s — together, against a cold
// server and a per-IP connection budget. Never above the un-jittered step.
func reconnectDelay(base time.Duration, attempt int, random func() float64) time.Duration {
	step := time.Duration(float64(base) * math.Pow(2, float64(attempt)))
	if step > maxReconnectDelay || step <= 0 {
		step = maxReconnectDelay
	}
	return step/2 + time.Duration(random()*float64(step/2))
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
//
// ctx bounds the handshake only. The connection then lives — reading,
// heartbeating, reconnecting — until Disconnect, whatever happens to ctx: it
// used to be handed to those loops too, so connecting with a request's context
// closed the socket when the request ended, and a listener connected from an
// HTTP handler received nothing afterwards. ctx's values (tracing and the
// like) are kept; only its cancellation and deadline are dropped.
func (c *Client) Connect(ctx context.Context) error {
	c.emitStatus(Status{State: StatusConnecting})
	conn, err := c.dial(ctx)
	if err != nil {
		return err
	}
	c.emitStatus(Status{State: StatusConnected})

	c.mu.Lock()
	c.conn = conn
	c.pendingHeartbeat = ""
	spawn := !c.started
	c.started = true
	c.mu.Unlock()

	if spawn {
		life, stop := context.WithCancel(context.WithoutCancel(ctx))
		c.mu.Lock()
		c.stop = stop
		c.mu.Unlock()
		go c.readLoop(life)
		go c.heartbeatLoop(life)
	}
	return nil
}

// Disconnect closes the connection gracefully.
func (c *Client) Disconnect() {
	first := false
	c.closeOnce.Do(func() {
		close(c.done)
		first = true
	})
	if first {
		defer c.emitStatus(Status{State: StatusDisconnected})
	}

	c.mu.Lock()
	conn := c.conn
	c.conn = nil
	c.started = false
	stop := c.stop
	c.stop = nil
	channels := c.channelList()
	c.mu.Unlock()

	if stop != nil {
		stop()
	}

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

// Channel returns (or creates) a channel for the given topic. Options only
// apply on creation; a later call asking for a different binary mode panics
// rather than silently handing back a channel in the other one.
func (c *Client) Channel(topic string, opts ...ChannelOption) *Channel {
	c.mu.Lock()
	defer c.mu.Unlock()

	if ch, ok := c.channels[topic]; ok {
		probe := &Channel{}
		for _, opt := range opts {
			opt(probe)
		}
		if probe.requestedMode != "" && modeOrDefault(probe.requestedMode) != modeOrDefault(ch.requestedMode) {
			panic(fmt.Sprintf("konet: %s already exists in %s mode", topic, modeOrDefault(ch.requestedMode)))
		}
		return ch
	}

	ch := newChannel(topic, c.send, c.sendBinary, c.nextRef, opts...)
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
		delay := reconnectDelay(c.opts.ReconnectDelay, attempt, rand.Float64)
		c.emitStatus(Status{State: StatusReconnecting, Attempt: attempt + 1, Delay: delay})

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

		c.emitStatus(Status{State: StatusConnecting})
		conn, err := c.dial(ctx)
		if err != nil {
			continue
		}

		c.mu.Lock()
		c.conn = conn
		c.mu.Unlock()
		c.emitStatus(Status{State: StatusConnected})

		// The server knows nothing about the topics this client had joined on
		// the previous socket. Re-issue phx_join — but from a goroutine, not
		// inline: a join blocks on its reply, and that reply can only arrive
		// through the read loop that is calling us.
		go c.rejoinChannels(ctx)
		return true
	}

	// Used to end silently: an application had no way to know the client had
	// stopped trying, short of polling Connected forever.
	c.emitStatus(Status{State: StatusFailed})
	return false
}

func (c *Client) rejoinChannels(ctx context.Context) {
	for _, ch := range c.snapshotChannels() {
		// One channel failing to re-join (an expired token, a room that now
		// refuses this client) must not stop the others.
		_ = ch.rejoin(ctx)
	}
}

func modeOrDefault(mode BinaryMode) BinaryMode {
	if mode == "" {
		return BinaryExclusive
	}
	return mode
}
