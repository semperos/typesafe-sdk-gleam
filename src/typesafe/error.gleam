import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/string

/// Every way a TypeSafe SDK call can fail.
pub type Error {
  /// The API returned a non-2xx response after any retries. `body` is the raw
  /// response text, `""` when the response had none.
  ApiError(
    status: Int,
    message: String,
    body: String,
    headers: List(#(String, String)),
    request_id: Option(String),
  )
  /// The request or the response body couldn't be delivered (DNS, TLS, a
  /// closed connection, and so on).
  ConnectionError(message: String)
  /// The full response didn't arrive within the timeout.
  TimeoutError(timeout_ms: Int)
  /// The request was rejected before sending because it is malformed.
  InvalidRequest(message: String)
  /// The client is misconfigured: a missing API key, an invalid setting, or
  /// an unsupported option for this runtime.
  InvalidConfig(message: String)
  /// A 2xx response didn't have the shape the SDK expects.
  UnexpectedResponse(message: String, body: String)
}

const max_raw_body_in_message = 200

/// The `ApiError` message for a status and response body: the server's own
/// message when one can be found, else the body, truncated.
pub fn describe(status: Int, body: String) -> String {
  let prefix = int.to_string(status) <> " "
  case body, extract_message(body) {
    "", _ -> prefix <> "status code (no body)"
    _, Ok(detail) -> prefix <> detail
    _, Error(Nil) ->
      case string.length(body) > max_raw_body_in_message {
        True -> prefix <> string.slice(body, 0, max_raw_body_in_message) <> "…"
        False -> prefix <> body
      }
  }
}

fn extract_message(body: String) -> Result(String, Nil) {
  case json.parse(body, message_decoder()) {
    Ok(message) -> Ok(message)
    Error(json.UnableToDecode(_)) -> Error(Nil)
    Error(_) -> Ok(body)
  }
}

fn message_decoder() -> decode.Decoder(String) {
  let text = non_empty(decode.string)
  let nested_message = decode.at(["message"], text)
  decode.one_of(text, [
    decode.at(["error"], text),
    decode.at(["error"], nested_message),
    decode.at(["message"], text),
    decode.at(["detail"], text),
    decode.at(["detail"], nested_message),
    decode.at(["detail"], validation_errors_decoder()),
  ])
}

fn non_empty(decoder: decode.Decoder(String)) -> decode.Decoder(String) {
  use text <- decode.then(decoder)
  case text {
    "" -> decode.failure("", "non-empty string")
    _ -> decode.success(text)
  }
}

/// Validation errors as semicolon-separated `path: message` entries.
fn validation_errors_decoder() -> decode.Decoder(String) {
  let location =
    decode.one_of(decode.string, [decode.int |> decode.map(int.to_string)])
  let entry =
    decode.one_of(
      {
        use msg <- decode.field("msg", decode.string)
        use loc <- decode.optional_field("loc", [], decode.list(location))
        let path = loc |> list.filter(fn(part) { part != "body" })
        case path {
          [] -> decode.success(Ok(msg))
          _ -> decode.success(Ok(string.join(path, ".") <> ": " <> msg))
        }
      },
      [decode.success(Error(Nil))],
    )
  use entries <- decode.then(decode.list(entry))
  case list.filter_map(entries, fn(entry) { entry }) {
    [] -> decode.failure("", "validation errors")
    parts -> decode.success(string.join(parts, "; "))
  }
}
