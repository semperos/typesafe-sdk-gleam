import gleam/list
import gleam/option.{None, Some}
import gleam/set
import typesafe/error.{InvalidConfig}
import typesafe/retry.{RetryPolicy}

const now = 1_700_000_000_000

pub fn default_policy_is_the_documented_sdk_default_test() {
  let policy = retry.default_policy()
  assert RetryPolicy(..policy, http_statuses: set.new())
    == RetryPolicy(
      max_retries: 2,
      backoff_initial_ms: 500,
      backoff_max_ms: 5000,
      backoff_jitter: 0.25,
      http_statuses: set.new(),
      respect_retry_after: True,
      max_retry_after_ms: 60_000,
      retry_connection_errors: True,
      retry_timeouts: True,
    )
  let retried = fn(status) { set.contains(policy.http_statuses, status) }
  assert list.all([408, 429, 500, 502, 503, 504, 529, 599], retried)
  assert !list.any([200, 400, 401, 403, 404, 409, 422, 600], retried)
}

pub fn parse_retry_after_reads_seconds_test() {
  assert retry.parse_retry_after([#("retry-after", "2")], now) == Some(2000)
  assert retry.parse_retry_after([#("retry-after", "1.5")], now) == Some(1500)
  assert retry.parse_retry_after([#("retry-after", "0")], now) == Some(0)
}

pub fn parse_retry_after_prefers_retry_after_ms_test() {
  assert retry.parse_retry_after(
      [#("retry-after", "2"), #("retry-after-ms", "250")],
      now,
    )
    == Some(250)
}

pub fn parse_retry_after_reads_an_http_date_relative_to_now_test() {
  // Tue, 14 Nov 2023 22:13:20 GMT is 1_700_000_000 seconds after the epoch.
  let headers = [#("retry-after", "Tue, 14 Nov 2023 22:13:25 GMT")]
  assert retry.parse_retry_after(headers, now) == Some(5000)
  assert retry.parse_retry_after(headers, now + 10_000) == Some(0)
}

pub fn parse_retry_after_ignores_missing_or_garbage_values_test() {
  assert retry.parse_retry_after([], now) == None
  assert retry.parse_retry_after([#("retry-after", "soon")], now) == None
  assert retry.parse_retry_after([#("retry-after", "-1")], now) == None
  assert retry.parse_retry_after([#("retry-after-ms", "x")], now) == None
}

fn delay(attempt, headers, policy, random) {
  retry.delay_ms(attempt, headers, policy, random, now)
}

pub fn delay_grows_exponentially_from_500ms_and_caps_at_5s_test() {
  let policy = retry.default_policy()
  assert list.map([0, 1, 2, 3, 4, 10], delay(_, [], policy, 0.0))
    == [500, 1000, 2000, 4000, 5000, 5000]
}

pub fn delay_shaves_off_at_most_25_percent_as_jitter_test() {
  let policy = retry.default_policy()
  assert delay(1, [], policy, 1.0) == 750
  assert delay(1, [], policy, 0.5) == 875
}

pub fn delay_honors_retry_after_exactly_test() {
  let policy = retry.default_policy()
  assert delay(0, [#("retry-after", "3")], policy, 1.0) == 3000
  // Over the one-minute ceiling, so backoff applies.
  assert delay(0, [#("retry-after", "61")], policy, 0.0) == 500
}

pub fn delay_uses_the_policy_settings_test() {
  let policy =
    RetryPolicy(
      ..retry.default_policy(),
      backoff_initial_ms: 100,
      backoff_max_ms: 300,
      backoff_jitter: 0.5,
      max_retry_after_ms: 1000,
    )
  assert list.map([0, 1, 2], delay(_, [], policy, 0.0)) == [100, 200, 300]
  assert delay(0, [], policy, 1.0) == 50
  assert delay(0, [#("retry-after", "2")], policy, 0.0) == 100
  let ignoring = RetryPolicy(..policy, respect_retry_after: False)
  assert delay(0, [#("retry-after-ms", "5")], ignoring, 0.0) == 100
}

pub fn validate_names_the_first_invalid_field_test() {
  let default = retry.default_policy()
  assert retry.validate(default) == Ok(default)
  assert retry.validate(RetryPolicy(..default, max_retries: -1))
    == Error(InvalidConfig(
      "Invalid retry policy: `max_retries` must be a non-negative integer, got -1.",
    ))
  assert retry.validate(RetryPolicy(..default, backoff_max_ms: -5))
    == Error(InvalidConfig(
      "Invalid retry policy: `backoff_max_ms` must be a non-negative number of milliseconds, got -5.",
    ))
  assert retry.validate(RetryPolicy(..default, backoff_jitter: 1.5))
    == Error(InvalidConfig(
      "Invalid retry policy: `backoff_jitter` must be between 0 and 1, got 1.5.",
    ))
  assert retry.validate(
      RetryPolicy(..default, http_statuses: set.from_list([503, 42])),
    )
    == Error(InvalidConfig(
      "Invalid retry policy: `http_statuses` must contain HTTP status codes, got 42.",
    ))
}
