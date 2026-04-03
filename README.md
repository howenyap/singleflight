# singleflight
Request deduplication for Gleam.

Concurrent requests for the same key are only execute once, all calls share the same result without repeated work.

# Blog
I wrote about how this works [here](https://howenyap.com/writings/single-flight-actors/)

# Install

```sh
gleam add singleflight
```

# Usage

```gleam
import gleam/io
import gleam/erlang/process
import gleam/otp/actor
import singleflight

pub fn main() -> Nil {
  let name = process.new_name("singleflight")
  let config = singleflight.config(1_000, 1_000)

  let assert Ok(actor.Started(data: server, ..)) =
    singleflight.start(config, name)

  let value =
    case singleflight.fetch(server, "key", fn(key) { key <> "-value" }) {
      Ok(value) -> value
      Error(singleflight.Crashed) -> panic as "singleflight worker crashed"
      Error(singleflight.TimedOut) -> panic as "singleflight request timed out"
    }

  io.debug(value)
}
```

## Errors
`fetch` returns `Error(singleflight.Crashed)` if the singleflight actor or the
worker process exits before producing a value.

`fetch` returns `Error(singleflight.TimedOut)` if no reply arrives within
`fetch_timeout_ms`.
