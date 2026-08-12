# 02 — konet-server

The Phoenix application. Read in order:

| File | Contents |
|---|---|
| [00-architecture.md](00-architecture.md) | Module layout, supervision tree, request paths, ETS state |
| [01-channels-presence-broadcast.md](01-channels-presence-broadcast.md) | `UserSocket`, `RoomChannel`, presence, broadcast, history |
| [02-binary-and-floor.md](02-binary-and-floor.md) | Binary frames, push-to-talk, `Konet.Floor` |
| [03-auth-ratelimit-webhooks.md](03-auth-ratelimit-webhooks.md) | JWT HMAC, scoped tokens, quotas, webhooks |
| [04-studio.md](04-studio.md) | The LiveView admin UI and how it is wired to the rest |
| [05-metrics.md](05-metrics.md) | `/metrics`, `/api/metrics`, telemetry |
