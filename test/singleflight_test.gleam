import gleam/erlang/process
import gleam/otp/actor
import gleeunit
import singleflight

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn same_key_deduplicates_to_one_request_test() {
  let server = start_test_server("singleflight_test_same_key")
  let started = process.new_subject()

  let first_result = process.new_subject()
  let second_result = process.new_subject()

  let work = fn(key) {
    let release = process.new_subject()
    process.send(started, release)

    let assert Ok("release") = process.receive(release, within: 1000)

    key
  }

  process.spawn(fn() {
    let result = singleflight.fetch(server, "foo", work)
    process.send(first_result, result)
  })

  let assert Ok(first_release) = process.receive(started, within: 1000)

  process.spawn(fn() {
    let result = singleflight.fetch(server, "foo", work)
    process.send(second_result, result)
  })

  let assert Error(Nil) = process.receive(started, within: 0)

  process.send(first_release, "release")

  let assert Ok(Ok("foo")) = process.receive(first_result, within: 1000)
  let assert Ok(Ok("foo")) = process.receive(second_result, within: 1000)

  let assert Error(Nil) = process.receive(started, within: 0)
}

pub fn different_keys_run_two_requests_test() {
  let server = start_test_server("singleflight_test_different_keys")
  let started = process.new_subject()

  let first_result = process.new_subject()
  let second_result = process.new_subject()

  let work = fn(key) {
    let release = process.new_subject()
    process.send(started, #(key, release))

    let assert Ok("release") = process.receive(release, within: 1000)

    key
  }

  process.spawn(fn() {
    let result = singleflight.fetch(server, "foo", work)
    process.send(first_result, result)
  })

  process.spawn(fn() {
    let result = singleflight.fetch(server, "bar", work)
    process.send(second_result, result)
  })

  let assert Ok(#("foo", foo_release)) = process.receive(started, within: 1000)
  let assert Ok(#("bar", bar_release)) = process.receive(started, within: 1000)
  let assert Error(Nil) = process.receive(started, within: 0)

  process.send(foo_release, "release")
  process.send(bar_release, "release")

  let assert Ok(Ok("foo")) = process.receive(first_result, within: 1000)
  let assert Ok(Ok("bar")) = process.receive(second_result, within: 1000)

  let assert Error(Nil) = process.receive(started, within: 0)
}

pub fn work_crash_returns_error_and_does_not_poison_key_test() {
  let server = start_test_server("singleflight_test_crash")

  let result_subject = process.new_subject()

  process.spawn(fn() {
    let result = singleflight.fetch(server, "foo", fn(_key) { panic as "boom" })
    process.send(result_subject, result)
  })

  let assert Ok(Error(singleflight.Crashed)) =
    process.receive(result_subject, within: 1000)

  let assert Ok("ok") = singleflight.fetch(server, "foo", fn(_key) { "ok" })
}

fn start_test_server(
  prefix: String,
) -> singleflight.Singleflight(String, String) {
  let name = process.new_name(prefix)
  let config = singleflight.config(1000, 1000)

  let assert Ok(actor.Started(data: server, ..)) =
    singleflight.start(config, name)

  server
}
