import gleam/list
import gleam/string
import helpers.{always, json_response, mock}
import typesafe.{TransportFailed}
import typesafe/content.{String}
import typesafe/logging.{Debug, Info, Notice}
import typesafe/question
import typesafe/retry

const key = "sk-live-abcdefghijklmnop"

const ok_body =
  "{\"model\":\"m\",\"answers\":{\"q\":{\"type\":\"noul\",\"noul\":1}}}"

fn logs_at(level, response) {
  let #(client, _) =
    typesafe.new(key)
    |> typesafe.with_retry(
      retry.RetryPolicy(..retry.default_policy(), max_retries: 0),
    )
    |> mock(always(response))
  let #(_, logs) =
    helpers.capture_logs(level, fn() {
      typesafe.system_one(
        client,
        typesafe.system_one_request(String("charged twice"), [
          #("q", question.noul(String("Billing?"))),
        ]),
      )
    })
  logs
}

/// Drop the request number, which differs between runs.
fn without_number(line: String) -> String {
  let assert Ok(#(_, rest)) = string.split_once(line, " POST ")
  "POST " <> rest
}

pub fn is_silent_at_the_erlang_default_level_test() {
  assert logs_at(Notice, Ok(json_response(200, ok_body))) == []
}

pub fn logs_one_summary_line_per_attempt_at_info_test() {
  let assert [#(Info, line)] = logs_at(Info, Ok(json_response(200, ok_body)))
  assert string.starts_with(line, "[typesafe-sdk] #")
  let assert "POST /v1/systemone <- 200 in " <> rest = without_number(line)
  assert string.ends_with(rest, "ms")
}

pub fn logs_headers_and_bodies_at_debug_without_the_raw_key_test() {
  let logs = logs_at(Debug, Ok(json_response(200, ok_body)))
  let assert [#(Debug, outgoing), #(Info, _), #(Debug, incoming)] = logs
  let outgoing = without_number(outgoing)
  assert string.starts_with(
    outgoing,
    "POST /v1/systemone -> https://api.typesafe.ai/v1/systemone headers: [",
  )
  assert string.contains(outgoing, "#(\"authorization\", \"Bearer ***mnop\")")
  assert string.ends_with(
    outgoing,
    "body: {\"state\":\"charged twice\",\"questions\":{\"q\":{\"type\":\"noul\",\"instructions\":\"Billing?\"}},\"model\":\"jev-latest\"}",
  )
  assert without_number(incoming) == "POST /v1/systemone <- body: " <> ok_body
  assert !list.any(logs, fn(line) { string.contains(line.1, key) })
}

pub fn logs_error_responses_with_their_body_at_debug_test() {
  let logs = logs_at(Debug, Ok(json_response(400, "{\"error\":\"bad\"}")))
  let assert [_, #(Info, summary), #(Debug, body)] = logs
  assert string.contains(summary, "<- 400 in ")
  assert without_number(body)
    == "POST /v1/systemone <- error body: {\"error\":\"bad\"}"
}

pub fn logs_connection_failures_with_the_cause_test() {
  let assert [#(Info, line)] =
    logs_at(Info, Error(TransportFailed("econnrefused")))
  assert string.contains(line, "connection error after ")
  assert string.ends_with(line, ": econnrefused")
}

pub fn redacts_short_secrets_without_a_tail_test() {
  let #(client, _) =
    typesafe.new("short")
    |> mock(always(Ok(json_response(200, "{\"models\":[]}"))))
  let #(_, logs) =
    helpers.capture_logs(Debug, fn() { typesafe.list_models(client) })
  let assert [#(Debug, outgoing), ..] = logs
  assert string.contains(outgoing, "#(\"authorization\", \"Bearer ***\")")
}
