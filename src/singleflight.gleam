import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/otp/actor

pub type Config {
  Config(initialisation_timeout_ms: Int, fetch_timeout_ms: Int)
}

pub type Message(k, v) {
  Request(key: k, work: fn(k) -> v, caller: process.Subject(v))
  Done(key: k, result: v)
}

pub opaque type Singleflight(k, v) {
  Singleflight(subject: process.Subject(Message(k, v)), fetch_timeout_ms: Int)
}

type State(k, v) {
  State(
    in_flight: dict.Dict(k, List(process.Subject(v))),
    self: process.Subject(Message(k, v)),
  )
}

pub fn config(initialisation_timeout_ms: Int, fetch_timeout_ms: Int) -> Config {
  Config(
    initialisation_timeout_ms: initialisation_timeout_ms,
    fetch_timeout_ms: fetch_timeout_ms,
  )
}

pub fn start(
  config: Config,
  name: process.Name(Message(k, v)),
) -> actor.StartResult(Singleflight(k, v)) {
  let Config(initialisation_timeout_ms:, fetch_timeout_ms:) = config

  actor.new_with_initialiser(initialisation_timeout_ms, fn(self) {
    actor.initialised(State(in_flight: dict.new(), self: self))
    |> actor.returning(Singleflight(
      subject: self,
      fetch_timeout_ms: fetch_timeout_ms,
    ))
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

pub fn fetch(singleflight: Singleflight(k, v), key: k, work: fn(k) -> v) -> v {
  let Singleflight(subject:, fetch_timeout_ms:) = singleflight

  actor.call(subject, fetch_timeout_ms, fn(caller) {
    Request(key: key, work: work, caller: caller)
  })
}

fn handle_message(
  state: State(k, v),
  message: Message(k, v),
) -> actor.Next(State(k, v), Message(k, v)) {
  case message {
    Request(key, work, caller) ->
      case dict.get(state.in_flight, key) {
        Ok(waiters) ->
          actor.continue(
            State(
              ..state,
              in_flight: dict.insert(state.in_flight, key, [caller, ..waiters]),
            ),
          )

        Error(Nil) -> {
          let self = state.self
          process.spawn(fn() {
            let result = work(key)
            actor.send(self, Done(key: key, result: result))
          })
          actor.continue(
            State(
              ..state,
              in_flight: dict.insert(state.in_flight, key, [caller]),
            ),
          )
        }
      }

    Done(key, result) -> {
      case dict.get(state.in_flight, key) {
        Ok(waiters) ->
          list.each(waiters, fn(waiter) { process.send(waiter, result) })
        Error(Nil) -> Nil
      }
      actor.continue(
        State(..state, in_flight: dict.delete(state.in_flight, key)),
      )
    }
  }
}
