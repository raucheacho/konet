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
})
```

Decode a payload into a struct with `konet.MarshalPayload(payload, &target)`.

## License

MIT
