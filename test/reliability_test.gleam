import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/set
import gleam/string
import helpers.{Sent, always, json_response, mock, sequence}
import typesafe.{TransportFailed, TransportTimeout}
import typesafe/content.{String}
import typesafe/error.{ApiError, ConnectionError, InvalidConfig, TimeoutError}
import typesafe/logging
import typesafe/question
import typesafe/retry.{RetryPolicy}

const ok_body =
  "{\"model\":\"m\",\"answers\":{\"q\":{\"type\":\"noul\",\"noul\":1}}}"

/// Retries without waiting more than a few milliseconds.
fn fast() {
  RetryPolicy(
    ..retry.default_policy(),
    backoff_initial_ms: 1,
    backoff_jitter: 0.0,
  )
}

fn run(policy, respond) {
  let #(client, sent) =
    typesafe.new("sk-test")
    |> typesafe.with_retry(policy)
    |> mock(respond)
  let #(result, logs) =
    helpers.capture_logs(logging.Info, fn() {
      typesafe.system_one(
        client,
        typesafe.system_one_request(String("s"), [
          #("q", question.noul(String("?"))),
        ]),
      )
    })
  let retries =
    list.filter_map(logs, fn(line) {
      case string.split_once(line.1, " retrying in ") {
        Ok(#(_, rest)) -> Ok(rest)
        Error(Nil) -> Error(Nil)
      }
    })
  #(result, list.length(sent()), retries, sent)
}

fn status(code) {
  Ok(json_response(code, "{\"error\":\"e" <> string.inspect(code) <> "\"}"))
}

pub fn retries_a_429_honoring_retry_after_test() {
  let limited =
    json_response(429, "{}") |> response.set_header("retry-after-ms", "3")
  let #(result, attempts, retries, _) =
    run(fast(), sequence([Ok(limited), Ok(json_response(200, ok_body))]))
  let assert Ok(_) = result
  assert attempts == 2
  assert retries == ["3ms (retry 1/2) after 429"]
}

pub fn backs_off_exponentially_without_retry_after_test() {
  let #(_, _, retries, _) =
    run(
      fast(),
      sequence([status(503), status(503), Ok(json_response(200, ok_body))]),
    )
  assert retries == ["1ms (retry 1/2) after 503", "2ms (retry 2/2) after 503"]
}

pub fn gives_up_after_max_retries_with_the_last_error_test() {
  let #(result, attempts, _, _) =
    run(fast(), sequence([status(500), status(502), status(503)]))
  let assert Error(ApiError(status: 503, message: "503 e503", ..)) = result
  assert attempts == 3
}

pub fn does_not_retry_other_statuses_test() {
  let #(result, attempts, _, _) = run(fast(), always(status(400)))
  let assert Error(ApiError(status: 400, ..)) = result
  assert attempts == 1
}

pub fn retries_connection_errors_test() {
  let #(result, attempts, retries, _) =
    run(
      fast(),
      sequence([
        Error(TransportFailed("closed")),
        Ok(json_response(200, ok_body)),
      ]),
    )
  let assert Ok(_) = result
  assert attempts == 2
  assert retries == ["1ms (retry 1/2) after Connection error: closed"]
}

pub fn tells_the_server_which_retry_this_is_test() {
  let #(_, _, _, sent) =
    run(fast(), sequence([status(503), status(503), status(503)]))
  assert list.map(sent(), fn(sent) {
      request.get_header(sent.request, "x-typesafe-retry-count")
    })
    == [Error(Nil), Ok("1"), Ok("2")]
}

pub fn resends_the_same_compressed_bytes_on_retry_test() {
  let #(client, sent) =
    typesafe.new("sk-test")
    |> typesafe.with_retry(fast())
    |> mock(sequence([status(503), Ok(json_response(200, ok_body))]))
  let assert Ok(_) =
    typesafe.system_one(
      client,
      typesafe.system_one_request(String(string.repeat("a", 5000)), [
        #("q", question.noul(String("?"))),
      ]),
    )
  let assert [Sent(request: first, ..), Sent(request: second, ..)] = sent()
  assert request.get_header(first, "content-encoding") == Ok("zstd")
  assert first.body == second.body
}

pub fn zero_max_retries_disables_retries_test() {
  let #(_, attempts, _, _) =
    run(RetryPolicy(..fast(), max_retries: 0), always(status(503)))
  assert attempts == 1
}

pub fn rejects_an_invalid_policy_before_sending_test() {
  let #(result, attempts, _, _) =
    run(RetryPolicy(..fast(), max_retries: -1), always(status(200)))
  let assert Error(InvalidConfig(_)) = result
  assert attempts == 0
}

pub fn retries_only_the_configured_statuses_test() {
  let policy = RetryPolicy(..fast(), http_statuses: set.from_list([409]))
  let #(_, conflicts, _, _) = run(policy, always(status(409)))
  let #(_, unavailable, _, _) = run(policy, always(status(503)))
  assert conflicts == 3
  assert unavailable == 1
}

pub fn retries_connection_errors_and_timeouts_independently_test() {
  let no_connection = RetryPolicy(..fast(), retry_connection_errors: False)
  let no_timeout = RetryPolicy(..fast(), retry_timeouts: False)
  let failed = always(Error(TransportFailed("reset")))
  let timed_out = always(Error(TransportTimeout))
  assert run(no_connection, failed).1 == 1
  assert run(no_connection, timed_out).1 == 3
  assert run(no_timeout, timed_out).1 == 1
  assert run(no_timeout, failed).1 == 3
}

pub fn caps_how_long_a_retry_after_may_be_test() {
  let limited =
    json_response(429, "{}") |> response.set_header("retry-after-ms", "50")
  let responses = sequence([Ok(limited), Ok(json_response(200, ok_body))])
  let #(_, _, capped, _) =
    run(RetryPolicy(..fast(), max_retry_after_ms: 10), responses)
  let #(_, _, ignored, _) =
    run(RetryPolicy(..fast(), respect_retry_after: False), responses)
  assert capped == ["1ms (retry 1/2) after 429"]
  assert ignored == ["1ms (retry 1/2) after 429"]
}

// ---------------------------------------------------------------------------
// Timeouts
// ---------------------------------------------------------------------------

pub fn passes_a_ten_second_default_timeout_to_each_attempt_test() {
  let #(_, _, _, sent) =
    run(
      fast(),
      sequence([Error(TransportTimeout), Ok(json_response(200, ok_body))]),
    )
  assert list.map(sent(), fn(sent) { sent.timeout_ms }) == [10_000, 10_000]
}

pub fn reports_a_timeout_after_retries_test() {
  let #(client, sent) =
    typesafe.new("sk-test")
    |> typesafe.with_retry(RetryPolicy(..fast(), max_retries: 1))
    |> typesafe.with_timeout(250)
    |> mock(always(Error(TransportTimeout)))
  assert typesafe.list_models(client) == Error(TimeoutError(250))
  assert list.map(sent(), fn(sent) { sent.timeout_ms }) == [250, 250]
}

pub fn rejects_a_non_positive_timeout_test() {
  let #(client, sent) =
    typesafe.new("sk-test")
    |> typesafe.with_timeout(0)
    |> mock(always(status(200)))
  assert typesafe.list_models(client)
    == Error(InvalidConfig(
      "`timeout_ms` must be a positive number of milliseconds, got 0.",
    ))
  assert sent() == []
}

pub fn connection_errors_without_retries_test() {
  let #(result, _, _, _) =
    run(
      RetryPolicy(..fast(), max_retries: 0),
      always(Error(TransportFailed("refused"))),
    )
  assert result == Error(ConnectionError("Connection error: refused"))
}
