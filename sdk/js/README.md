# @raucheacho/konet-js

Type-safe JavaScript/TypeScript client for [Konet](https://github.com/raucheacho/konet),
the self-hosted realtime engine (channels, presence, broadcast). Works in
browsers and Node.js.

## Install

```bash
npm install @raucheacho/konet-js
```

## Usage

```ts
import { createClient } from '@raucheacho/konet-js'

const client = createClient('ws://localhost:4000/socket', {
  token: '<anon_key>',
})

const channel = client.channel('room:lobby')
await channel.subscribe()

channel.on('message', (payload) => console.log('Received:', payload))
channel.send('message', { text: 'Hello!' })
```

`createClient` connects immediately. Call `client.disconnect()` to close the socket.

## Options

```ts
interface KonetClientOptions {
  token: string
  heartbeatIntervalMs?: number   // default: 30000
  reconnectDelayMs?: number      // default: 1000
  maxReconnectAttempts?: number  // default: 10
}
```

## Presence

```ts
channel.on('presence', (users) => console.log('Online:', users.length))

// or read the current snapshot
const users = channel.getPresence().list()
```

## License

MIT
