import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/otp/actor

pub type Config {
  Config(initialisation_timeout_ms: Int, fetch_timeout_ms: Int)
}

pub type FetchError {
  Crashed
  TimedOut
}

pub type FetchResult(v) =
  Result(v, FetchError)

type ReplySubject(v) =
  process.Subject(FetchResult(v))

pub type Message(k, v) {
  Request(key: k, work: fn(k) -> v, caller: ReplySubject(v))
  Done(pid: process.Pid, key: k, result: FetchResult(v))
  WorkerDown(pid: process.Pid)
}

pub opaque type Singleflight(k, v) {
  Singleflight(subject: process.Subject(Message(k, v)), fetch_timeout_ms: Int)
}

type State(k, v) {
  State(
    in_flight: dict.Dict(k, List(ReplySubject(v))),
    workers: dict.Dict(process.Pid, k),
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
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(pid: pid, ..) -> WorkerDown(pid: pid)
          process.PortDown(..) -> WorkerDown(pid: process.self())
        }
      })

    actor.initialised(State(
      in_flight: dict.new(),
      workers: dict.new(),
      self: self,
    ))
    |> actor.selecting(selector)
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

pub fn fetch(
  singleflight: Singleflight(k, v),
  key: k,
  work: fn(k) -> v,
) -> FetchResult(v) {
  let Singleflight(subject:, fetch_timeout_ms:) = singleflight

  case process.subject_owner(subject) {
    Ok(actor_pid) -> {
      let caller = process.new_subject()
      let monitor = process.monitor(actor_pid)

      process.send(subject, Request(key: key, work: work, caller: caller))

      let result =
        process.new_selector()
        |> process.select(caller)
        |> process.select_specific_monitor(monitor, fn(_) { Error(Crashed) })
        |> process.selector_receive(within: fetch_timeout_ms)

      process.demonitor_process(monitor)

      case result {
        Ok(result) -> result
        Error(Nil) -> Error(TimedOut)
      }
    }
    Error(Nil) -> Error(Crashed)
  }
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
          let worker_pid =
            process.spawn_unlinked(fn() {
              let result = work(key)

              actor.send(
                self,
                Done(pid: process.self(), key: key, result: Ok(result)),
              )
            })

          process.monitor(worker_pid)

          actor.continue(
            State(
              ..state,
              in_flight: dict.insert(state.in_flight, key, [caller]),
              workers: dict.insert(state.workers, worker_pid, key),
            ),
          )
        }
      }

    WorkerDown(pid) ->
      case dict.get(state.workers, pid) {
        Ok(key) -> {
          case dict.get(state.in_flight, key) {
            Ok(waiters) ->
              list.each(waiters, fn(waiter) {
                process.send(waiter, Error(Crashed))
              })

            Error(Nil) -> Nil
          }

          actor.continue(
            State(
              ..state,
              in_flight: dict.delete(state.in_flight, key),
              workers: dict.delete(state.workers, pid),
            ),
          )
        }

        Error(Nil) -> actor.continue(state)
      }

    Done(pid, key, result) -> {
      case dict.get(state.in_flight, key) {
        Ok(waiters) ->
          list.each(waiters, fn(waiter) { process.send(waiter, result) })

        Error(Nil) -> Nil
      }

      actor.continue(
        State(
          ..state,
          in_flight: dict.delete(state.in_flight, key),
          workers: dict.delete(state.workers, pid),
        ),
      )
    }
  }
}
