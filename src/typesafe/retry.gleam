import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import typesafe/error.{type Error, InvalidConfig}

/// When and how long to wait before retrying a failed request. Override
/// fields with record update syntax:
///
/// ```gleam
/// retry.RetryPolicy(..retry.default_policy(), max_retries: 5)
/// ```
pub type RetryPolicy {
  RetryPolicy(
    /// Retries after the initial attempt; `0` disables retries.
    max_retries: Int,
    /// First backoff delay, doubled on each retry up to `backoff_max_ms`.
    backoff_initial_ms: Int,
    backoff_max_ms: Int,
    /// Fraction of each backoff delay randomly subtracted, from 0 to 1.
    backoff_jitter: Float,
    /// HTTP status codes to retry.
    http_statuses: Set(Int),
    /// Honor `retry-after-ms` and `Retry-After` up to `max_retry_after_ms`.
    respect_retry_after: Bool,
    /// Longest server-requested delay to honor; longer ones use backoff.
    max_retry_after_ms: Int,
    retry_connection_errors: Bool,
    retry_timeouts: Bool,
  )
}

/// Two retries with backoff from 500ms to 5s and 25% jitter, retrying 408,
/// 429, 5xx, connection errors, and timeouts, and honoring `Retry-After` up
/// to one minute.
pub fn default_policy() -> RetryPolicy {
  RetryPolicy(
    max_retries: 2,
    backoff_initial_ms: 500,
    backoff_max_ms: 5000,
    backoff_jitter: 0.25,
    http_statuses: set.from_list([
      408,
      429,
      ..int.range(500, 600, [], list.prepend)
    ]),
    respect_retry_after: True,
    max_retry_after_ms: 60_000,
    retry_connection_errors: True,
    retry_timeouts: True,
  )
}

/// Check every field, naming the first invalid one.
pub fn validate(policy: RetryPolicy) -> Result(RetryPolicy, Error) {
  let invalid_status =
    set.to_list(policy.http_statuses)
    |> list.find(fn(status) { status < 100 || status > 999 })
  let problem = case policy {
    RetryPolicy(max_retries: n, ..) if n < 0 ->
      Some(
        "`max_retries` must be a non-negative integer, got " <> int.to_string(n),
      )
    RetryPolicy(backoff_initial_ms: n, ..) if n < 0 ->
      Some(negative_ms("backoff_initial_ms", n))
    RetryPolicy(backoff_max_ms: n, ..) if n < 0 ->
      Some(negative_ms("backoff_max_ms", n))
    RetryPolicy(max_retry_after_ms: n, ..) if n < 0 ->
      Some(negative_ms("max_retry_after_ms", n))
    RetryPolicy(backoff_jitter: j, ..) if j <. 0.0 || j >. 1.0 ->
      Some(
        "`backoff_jitter` must be between 0 and 1, got " <> float.to_string(j),
      )
    _ ->
      case invalid_status {
        Ok(status) ->
          Some(
            "`http_statuses` must contain HTTP status codes, got "
            <> int.to_string(status),
          )
        Error(Nil) -> None
      }
  }
  case problem {
    Some(message) ->
      Error(InvalidConfig("Invalid retry policy: " <> message <> "."))
    None -> Ok(policy)
  }
}

fn negative_ms(field: String, value: Int) -> String {
  "`"
  <> field
  <> "` must be a non-negative number of milliseconds, got "
  <> int.to_string(value)
}

/// The server-requested retry delay in milliseconds, from `retry-after-ms` or
/// else `Retry-After` (seconds or an HTTP date relative to `now_ms`).
pub fn parse_retry_after(
  headers: List(#(String, String)),
  now_ms: Int,
) -> Option(Int) {
  let ms = case list.key_find(headers, "retry-after-ms") {
    Ok(raw) -> parse_number(raw) |> option.from_result
    Error(Nil) -> None
  }
  case ms, list.key_find(headers, "retry-after") {
    Some(ms), _ if ms >=. 0.0 -> Some(float.round(ms))
    _, Error(Nil) -> None
    _, Ok(raw) ->
      case parse_number(raw) {
        Ok(seconds) if seconds >=. 0.0 -> Some(float.round(seconds *. 1000.0))
        Ok(_) -> None
        Error(Nil) ->
          case parse_http_date_ms(string.trim(raw)) {
            Ok(date_ms) -> Some(int.max(0, date_ms - now_ms))
            Error(Nil) -> None
          }
      }
  }
}

fn parse_number(raw: String) -> Result(Float, Nil) {
  let raw = string.trim(raw)
  case int.parse(raw) {
    Ok(n) -> Ok(int.to_float(n))
    Error(Nil) -> float.parse(raw)
  }
}

/// The delay before zero-based retry `attempt`: an allowed server-requested
/// delay from `headers`, else capped exponential backoff minus up to
/// `backoff_jitter` of it, scaled by `random` (from 0 to 1).
pub fn delay_ms(
  attempt: Int,
  headers: List(#(String, String)),
  policy: RetryPolicy,
  random: Float,
  now_ms: Int,
) -> Int {
  let retry_after = case policy.respect_retry_after {
    True -> parse_retry_after(headers, now_ms)
    False -> None
  }
  case retry_after {
    Some(ms) if ms <= policy.max_retry_after_ms -> ms
    _ -> {
      let exponential =
        int.min(
          int.bitwise_shift_left(policy.backoff_initial_ms, attempt),
          policy.backoff_max_ms,
        )
      float.round(
        int.to_float(exponential) *. { 1.0 -. random *. policy.backoff_jitter },
      )
    }
  }
}

@external(erlang, "typesafe_ffi", "parse_http_date_ms")
fn parse_http_date_ms(text: String) -> Result(Int, Nil)
