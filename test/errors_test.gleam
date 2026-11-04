import gleam/http/response
import gleam/option.{None, Some}
import helpers.{always, json_response, mock}
import typesafe
import typesafe/content.{String}
import typesafe/error.{ApiError}
import typesafe/question
import typesafe/retry

fn failing(response) {
  let #(client, _) =
    typesafe.new("sk-test")
    |> typesafe.with_retry(
      retry.RetryPolicy(..retry.default_policy(), max_retries: 0),
    )
    |> mock(always(Ok(response)))
  let assert Error(error) =
    typesafe.system_one(
      client,
      typesafe.system_one_request(String("s"), [
        #("q", question.noul(String("?"))),
      ]),
    )
  error
}

pub fn api_errors_carry_the_status_body_headers_and_request_id_test() {
  let body = "{\"error\":{\"message\":\"Invalid API key\"}}"
  assert failing(
      json_response(401, body)
      |> response.set_header("x-typesafe-request-id", "req_42"),
    )
    == ApiError(
      status: 401,
      message: "401 Invalid API key",
      body:,
      headers: [
        #("content-type", "application/json"),
        #("x-typesafe-request-id", "req_42"),
      ],
      request_id: Some("req_42"),
    )
}

pub fn describe_extracts_the_servers_message_test() {
  assert error.describe(400, "{\"error\":\"bad input\"}") == "400 bad input"
  assert error.describe(400, "{\"error\":{\"message\":\"nested\"}}")
    == "400 nested"
  assert error.describe(404, "{\"message\":\"not here\"}") == "404 not here"
  assert error.describe(403, "{\"detail\":\"forbidden\"}") == "403 forbidden"
  assert error.describe(500, "{\"detail\":{\"message\":\"boom\"}}")
    == "500 boom"
  assert error.describe(
      422,
      "{\"detail\":[{\"loc\":[\"body\",\"questions\",0],\"msg\":\"required\"},{\"msg\":\"bad\"},{\"x\":1}]}",
    )
    == "422 questions.0: required; bad"
}

pub fn describe_falls_back_to_the_raw_body_truncated_test() {
  let long = "{\"other\":\"" <> string_of(300) <> "\"}"
  assert error.describe(500, long)
    == "500 {\"other\":\"" <> string_of(190) <> "…"
}

fn string_of(n) {
  case n {
    0 -> ""
    _ -> "x" <> string_of(n - 1)
  }
}

pub fn describe_keeps_text_bodies_and_handles_empty_ones_test() {
  assert error.describe(502, "Bad Gateway") == "502 Bad Gateway"
  assert error.describe(503, "") == "503 status code (no body)"
}

pub fn api_errors_without_a_request_id_have_none_test() {
  let assert ApiError(request_id: None, message: "502 upstream down", ..) =
    failing(response.new(502) |> response.set_body(<<"upstream down">>))
}

pub fn describe_ignores_empty_messages_test() {
  assert error.describe(400, "{\"message\":\"\"}") == "400 {\"message\":\"\"}"
  assert error.describe(400, "{\"error\":\"\",\"message\":\"real\"}")
    == "400 real"
}

pub fn decodes_invalid_utf8_error_bodies_lossily_test() {
  let assert ApiError(
    message: "502 Bad gateway \u{FFFD}",
    body: "Bad gateway \u{FFFD}",
    ..,
  ) = failing(response.new(502) |> response.set_body(<<"Bad gateway ", 0xff>>))
}
