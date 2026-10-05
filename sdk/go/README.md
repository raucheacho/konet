# konet (Go SDK)

Lightweight WebSocket client for [Konet](https://github.com/raucheacho/konet),
the self-hosted realtime engine (channels, presence, broadcast).

## Install

```bash
go get github.com/raucheacho/konet/sdk/go
```

## Usage

```go
package main

import (
    "context"
    "log"

    konet "github.com/raucheacho/konet/sdk/go"
)

func main() {
    ctx := context.Background()

    client := konet.New("ws://localhost:4000/socket", "<anon_key>")
    if err := client.Connect(ctx); err != nil {
        log.Fatal(err)
    }
    defer client.Disconnect()

    ch := client.Channel("room:lobby")
    if err := ch.Subscribe(ctx); err != nil {
        log.Fatal(err)
    }

    ch.On("message", func(payload interface{}) {
        log.Printf("recv: %+v\n", payload)
    })

    ch.Send("message", map[string]any{"text": "Hello from Go!"})

    select {} // block
}
```

## Options

```go
client := konet.New(url, token, konet.ClientOptions{
    HeartbeatInterval: 30 * time.Second,
    ReconnectDelay:    time.Second,
    MaxReconnectTries: 10,
    HTTPHeader:        nil, // extra headers for the WS handshake
    // StatusConnecting, StatusConnected, StatusReconnecting (s.Attempt, s.Delay),
    // StatusDisconnected, StatusFailed. Runs on the client's goroutine.
    OnStatus: func(s konet.Status) {},
})
```

Reconnect delays are exponential with jitter (between half and all of each
step, capped at 30 s), so clients dropped together do not come back in lockstep.

Decode a payload into a struct with `konet.MarshalPayload(payload, &target)`.

## Binary frames

For audio or anything else at a media rate. Each topic runs one of two modes,
chosen when the channel is created; every member must ask for the same one.

```go
// Push-to-talk — BinaryExclusive, the default: one sender at a time, by floor.
ptt := client.Channel("room:team-42:ptt")
_ = ptt.Subscribe(ctx)
holder, err := ptt.AcquireFloor(ctx) // err names the holder if taken
_ = ptt.SendBinary("a", frame)       // frame is copied
_ = ptt.ReleaseFloor(ctx)
ptt.OnBinary("a", func(data []byte) {}) // synchronous, in arrival order

// A call — BinaryMultiplex: everyone sends at once, no floor.
call := client.Channel("room:call-7", konet.WithBinaryMode(konet.BinaryMultiplex))
_ = call.Subscribe(ctx)
call.OnBinaryFrom("a", func(data []byte, sender string) {})
_ = call.SendBinary("a", frame)

// A refused frame (no floor, rate limited), at most once per reason per second.
call.On("binary_error", func(p interface{}) {
    e := p.(konet.BinaryError) // e.Topic, e.Reason
    _ = e
})
```

`call.BinaryMode()` returns the mode the server confirmed. A join asking for the
other mode than the topic's members fails with `binary_mode_mismatch`; a
multiplex topic beyond the server's member ceiling, with `topic_full`.
Details: [binary frames](https://raucheacho.github.io/konet/reference/binary).

## License

MIT
