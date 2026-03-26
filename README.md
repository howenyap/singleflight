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
    
  let value = singleflight.fetch(server, "key", fn(key) { key <> "-value" })

  io.debug(value)
}
