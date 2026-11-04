//// A client for the TypeSafe AI API.
////
//// ```gleam
//// import typesafe
//// import typesafe/content.{String}
//// import typesafe/question
////
//// let assert Ok(client) = typesafe.from_env()
//// let assert Ok(result) =
////   typesafe.system_one(
////     client,
////     typesafe.system_one_request(String("I was charged twice."), [
////       #("billing", question.noul(String("Is this about billing?"))),
////     ]),
////   )
//// ```

import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import gleam/uri
import typesafe/content.{type Content, type Image, Null, Object}
import typesafe/error.{
  type Error, ApiError, ConnectionError, InvalidConfig, InvalidRequest,
  TimeoutError, UnexpectedResponse,
}
import typesafe/logging.{type LogLevel, Debug, Info}
import typesafe/question.{type Answer, type Question}
import typesafe/retry.{type RetryPolicy}

pub const version = "1.0.0"

pub const default_base_url = "https://api.typesafe.ai"

pub const default_model = "jev-latest"

const default_timeout_ms = 10_000

/// Bodies this small fit in a single TCP segment, so they're sent
/// uncompressed.
const min_compressed_body_bytes = 1024

const request_id_header = "x-typesafe-request-id"

/// Request body compression, sent as `Content-Encoding`.
pub type Compression {
  /// Requires OTP 28 or newer.
  Zstd
  NoCompression
}

/// Why a transport couldn't deliver a request.
pub type TransportError {
  TransportTimeout
  TransportFailed(message: String)
}

/// Sends one HTTP request, waiting at most the given milliseconds for the
/// full response.
pub type Transport =
  fn(Request(BitArray), Int) -> Result(Response(BitArray), TransportError)

/// Connection settings for the API. Every setting is optional except the API
/// key; build one with `new` or `from_env` and override settings with the
/// `with_` functions, including for a single call.
pub opaque type Client {
  Client(
    api_key: String,
    base_url: String,
    default_model: String,
    retry: RetryPolicy,
    timeout_ms: Int,
    headers: List(#(String, String)),
    compression: Compression,
    transport: Transport,
  )
}

/// A client with the SDK defaults: the production API, the `jev-latest`
/// model, the default retry policy, a 10 second timeout per attempt, zstd compression when the runtime has it,
/// and `gleam_httpc` for transport.
pub fn new(api_key: String) -> Client {
  Client(
    api_key:,
    base_url: default_base_url,
    default_model:,
    retry: retry.default_policy(),
    timeout_ms: default_timeout_ms,
    headers: [],
    compression: case has_zstd() {
      True -> Zstd
      False -> NoCompression
    },
    transport: httpc_transport,
  )
}

/// A client configured from `TYPESAFE_API_KEY` (required),
/// `TYPESAFE_BASE_URL`, and `TYPESAFE_DEFAULT_MODEL`.
/// Blank values count as unset.
pub fn from_env() -> Result(Client, Error) {
  use api_key <- result.map(
    read_env("TYPESAFE_API_KEY")
    |> option.to_result(InvalidConfig(
      "No API key was provided. Pass one to `new` or set the TYPESAFE_API_KEY environment variable.",
    )),
  )
  let client = new(api_key)
  let client = case read_env("TYPESAFE_BASE_URL") {
    Some(url) -> with_base_url(client, url)
    None -> client
  }
  case read_env("TYPESAFE_DEFAULT_MODEL") {
    Some(model) -> with_default_model(client, model)
    None -> client
  }
}

fn read_env(name: String) -> Option(String) {
  case get_env(name) {
    Ok(value) ->
      case string.trim(value) {
        "" -> None
        trimmed -> Some(trimmed)
      }
    Error(Nil) -> None
  }
}

/// The API root, with trailing slashes removed.
pub fn with_base_url(client: Client, base_url: String) -> Client {
  Client(..client, base_url: strip_trailing_slashes(base_url))
}

fn strip_trailing_slashes(url: String) -> String {
  case string.ends_with(url, "/") {
    True -> strip_trailing_slashes(string.drop_end(url, 1))
    False -> url
  }
}

/// The model used when a request doesn't name one.
pub fn with_default_model(client: Client, model: String) -> Client {
  Client(..client, default_model: model)
}

pub fn with_retry(client: Client, policy: RetryPolicy) -> Client {
  Client(..client, retry: policy)
}

/// The timeout for each attempt, including reading the response body. There
/// is no total budget across retries.
pub fn with_timeout(client: Client, timeout_ms: Int) -> Client {
  Client(..client, timeout_ms:)
}

/// An extra header for every request, replacing any earlier value for the
/// same name. Headers the SDK sets, such as `authorization`, take precedence.
pub fn with_header(client: Client, name: String, value: String) -> Client {
  let name = string.lowercase(name)
  Client(..client, headers: list.key_set(client.headers, name, value))
}

/// Bodies under 1 KiB are always sent uncompressed.
pub fn with_compression(client: Client, compression: Compression) -> Client {
  Client(..client, compression:)
}

/// Replace `gleam_httpc`, for example to configure TLS or in tests.
pub fn with_transport(client: Client, transport: Transport) -> Client {
  Client(..client, transport:)
}

// ---------------------------------------------------------------------------
// System One
// ---------------------------------------------------------------------------

/// State to evaluate and named questions about it.
pub type SystemOneRequest {
  SystemOneRequest(
    /// Any content except `Null`.
    state: Content,
    /// Answers are keyed by these names, which must be unique.
    questions: List(#(String, Question)),
    /// `None` uses the client's default model.
    model: Option(String),
    /// Images to reference by a name of your choice. Each name is matched
    /// literally in the request's strings, so use distinct delimiters such
    /// as `<photo>`, and each must appear somewhere in the request. Images
    /// placed in content directly don't need to be listed.
    assets: List(#(String, Image)),
  )
}

/// A request using the default model and no named assets.
pub fn system_one_request(
  state: Content,
  questions: List(#(String, Question)),
) -> SystemOneRequest {
  SystemOneRequest(state:, questions:, model: None, assets: [])
}

pub type SystemOneResult {
  SystemOneResult(model: String, answers: Dict(String, Answer), usage: Usage)
}

/// Token counts, `None` when the API didn't report them.
pub type Usage {
  Usage(input_tokens: Option(Int), output_tokens: Option(Int))
}

/// Answer named questions about text, structured state, or images.
pub fn system_one(
  client: Client,
  request: SystemOneRequest,
) -> Result(SystemOneResult, Error) {
  build_system_one(client, request)
  |> result.try(send(client, _))
  |> result.try(parse_system_one)
}

/// The HTTP request `system_one` sends, before `send` adds authentication.
pub fn build_system_one(
  client: Client,
  request: SystemOneRequest,
) -> Result(Request(BitArray), Error) {
  use <- bool.guard(
    request.state == Null,
    Error(InvalidRequest("State is required.")),
  )
  use Nil <- result.try(question.validate(request.questions))
  let questions =
    list.map(request.questions, fn(entry) {
      #(entry.0, question.to_content(entry.1))
    })
  let model = option.unwrap(request.model, client.default_model)
  use serialized <- result.try(content.serialize(
    [
      #("state", request.state),
      #("questions", Object(questions)),
      #("model", content.String(model)),
    ],
    request.assets,
  ))
  let #(body, content_type) = case serialized.assets {
    [] -> #(
      bit_array.from_string(json.to_string(json.object(serialized.fields))),
      "application/json",
    )
    _ -> {
      let boundary = random_hex()
      #(
        content.multipart(serialized, boundary),
        "multipart/form-data; boundary=" <> boundary,
      )
    }
  }
  use http_request <- result.map(base_request(
    client,
    http.Post,
    "/v1/systemone",
  ))
  http_request
  |> request.set_body(body)
  |> request.set_header("content-type", content_type)
}

pub fn parse_system_one(
  response: Response(BitArray),
) -> Result(SystemOneResult, Error) {
  let usage = {
    let count = decode.optional(decode.int)
    use input_tokens <- decode.optional_field("input_tokens", None, count)
    use output_tokens <- decode.optional_field("output_tokens", None, count)
    decode.success(Usage(input_tokens:, output_tokens:))
  }
  parse_json(response, "POST /v1/systemone", {
    use model <- decode.field("model", decode.string)
    use answers <- decode.field(
      "answers",
      decode.dict(decode.string, question.answer_decoder()),
    )
    use usage <- decode.optional_field("usage", None, decode.optional(usage))
    let usage = option.unwrap(usage, Usage(None, None))
    decode.success(SystemOneResult(model:, answers:, usage:))
  })
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

pub type ModelCard {
  ModelCard(name: String, description: String, release_date: String)
}

/// The models available to the account.
pub fn list_models(client: Client) -> Result(List(ModelCard), Error) {
  build_list_models(client)
  |> result.try(send(client, _))
  |> result.try(parse_list_models)
}

pub fn build_list_models(client: Client) -> Result(Request(BitArray), Error) {
  base_request(client, http.Get, "/v1/models")
}

pub fn parse_list_models(
  response: Response(BitArray),
) -> Result(List(ModelCard), Error) {
  let card = {
    use name <- decode.field("name", decode.string)
    use description <- decode.field("description", decode.string)
    use release_date <- decode.field("release_date", decode.string)
    decode.success(ModelCard(name:, description:, release_date:))
  }
  parse_json(
    response,
    "GET /v1/models",
    decode.at(["models"], decode.list(card)),
  )
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

fn base_request(
  client: Client,
  method: http.Method,
  path: String,
) -> Result(Request(BitArray), Error) {
  case request.to(client.base_url <> path) {
    Ok(http_request) ->
      Ok(http_request |> request.set_method(method) |> request.set_body(<<>>))
    Error(Nil) -> Error(InvalidConfig("Invalid base URL: " <> client.base_url))
  }
}

fn parse_json(
  response: Response(BitArray),
  endpoint: String,
  decoder: decode.Decoder(a),
) -> Result(a, Error) {
  let body = body_text(response.body)
  json.parse(body, decoder)
  |> result.replace_error(UnexpectedResponse(
    "Unexpected response shape from " <> endpoint <> ".",
    body,
  ))
}

/// Headers the SDK owns, which a client's or request's headers can't set.
const protected_headers = [
  "authorization", "accept", "user-agent", "x-typesafe-sdk",
  "x-typesafe-runtime", "content-type", "content-encoding",
  "x-typesafe-retry-count",
]

/// Send a request with authentication, compression, and retries, returning
/// the response once a 2xx arrives. A non-2xx response that isn't retried
/// is an `ApiError`. Response header names are lowercased.
pub fn send(
  client: Client,
  http_request: Request(BitArray),
) -> Result(Response(BitArray), Error) {
  use policy <- result.try(retry.validate(client.retry))
  use <- bool.guard(
    client.timeout_ms <= 0,
    Error(InvalidConfig(
      "`timeout_ms` must be a positive number of milliseconds, got "
      <> int.to_string(client.timeout_ms)
      <> ".",
    )),
  )
  use <- bool.guard(
    client.compression == Zstd && !has_zstd(),
    Error(InvalidConfig(
      "zstd compression requires OTP 28 or newer. Use `with_compression(NoCompression)` instead.",
    )),
  )
  let payload = http_request.body
  let compressed =
    client.compression == Zstd
    && bit_array.byte_size(payload) >= min_compressed_body_bytes
  let content_type = case payload {
    <<>> -> Error(Nil)
    _ -> request.get_header(http_request, "content-type")
  }
  let sdk_headers =
    [
      Ok(#("authorization", "Bearer " <> client.api_key)),
      Ok(#("accept", "application/json")),
      Ok(#("user-agent", "typesafe-sdk-gleam/" <> version)),
      Ok(#("x-typesafe-sdk", "typesafe-sdk-gleam/" <> version)),
      Ok(#("x-typesafe-runtime", runtime())),
      result.map(content_type, fn(value) { #("content-type", value) }),
      case compressed {
        True -> Ok(#("content-encoding", "zstd"))
        False -> Error(Nil)
      },
    ]
    |> result.values
  let headers =
    list.fold(http_request.headers, client.headers, fn(headers, header) {
      list.key_set(headers, string.lowercase(header.0), header.1)
    })
    |> list.filter(fn(header) { !list.contains(protected_headers, header.0) })
    |> list.append(sdk_headers)
  let prepared =
    request.Request(..http_request, headers:, body: case compressed {
      True -> zstd_compress(payload)
      False -> payload
    })
  let tag =
    "#"
    <> int.to_string(unique_id())
    <> " "
    <> http.method_to_string(http_request.method)
    |> string.uppercase
    <> " "
    <> http_request.path
  send_attempt(client, policy, tag, prepared, payload, 0)
}

fn send_attempt(
  client: Client,
  policy: RetryPolicy,
  tag: String,
  http_request: Request(BitArray),
  payload: BitArray,
  attempt: Int,
) -> Result(Response(BitArray), Error) {
  let retries_left = policy.max_retries - attempt
  let http_request = case attempt {
    0 -> http_request
    _ ->
      request.set_header(
        http_request,
        "x-typesafe-retry-count",
        int.to_string(attempt),
      )
  }
  let url = request.to_uri(http_request) |> uri.to_string
  log_lazy(Debug, fn() {
    tag
    <> " -> "
    <> url
    <> " headers: "
    <> string.inspect(redact_headers(http_request.headers))
    <> " body: "
    <> describe_body(payload)
  })
  let started = monotonic_ms()
  let elapsed = fn() { int.to_string(monotonic_ms() - started) <> "ms" }
  let retry = fn(reason, headers) {
    let delay =
      retry.delay_ms(attempt, headers, policy, float.random(), system_time_ms())
    log_lazy(Info, fn() {
      tag
      <> " retrying in "
      <> int.to_string(delay)
      <> "ms (retry "
      <> int.to_string(attempt + 1)
      <> "/"
      <> int.to_string(policy.max_retries)
      <> ") after "
      <> reason
    })
    sleep(delay)
    send_attempt(client, policy, tag, http_request, payload, attempt + 1)
  }
  case client.transport(http_request, client.timeout_ms) {
    Error(TransportTimeout) -> {
      log_lazy(Info, fn() { tag <> " timed out after " <> elapsed() })
      let error = TimeoutError(client.timeout_ms)
      case retries_left > 0 && policy.retry_timeouts {
        True -> retry("timeout", [])
        False -> Error(error)
      }
    }
    Error(TransportFailed(message)) -> {
      log_lazy(Info, fn() {
        tag <> " connection error after " <> elapsed() <> ": " <> message
      })
      let error = ConnectionError("Connection error: " <> message)
      case retries_left > 0 && policy.retry_connection_errors {
        True -> retry(error.message, [])
        False -> Error(error)
      }
    }
    Ok(response) -> {
      let headers =
        list.map(response.headers, fn(header) {
          #(string.lowercase(header.0), header.1)
        })
      let response = response.Response(..response, headers:)
      let request_id =
        option.from_result(list.key_find(headers, request_id_header))
      log_lazy(Info, fn() {
        tag
        <> " <- "
        <> int.to_string(response.status)
        <> " in "
        <> elapsed()
        <> case request_id {
          Some(id) -> " (request " <> id <> ")"
          None -> ""
        }
      })
      let body = body_text(response.body)
      case response.status >= 200 && response.status < 300 {
        True -> {
          log_lazy(Debug, fn() { tag <> " <- body: " <> body })
          Ok(response)
        }
        False -> {
          log_lazy(Debug, fn() { tag <> " <- error body: " <> body })
          case
            retries_left > 0
            && set.contains(policy.http_statuses, response.status)
          {
            True -> retry(int.to_string(response.status), headers)
            False ->
              Error(ApiError(
                status: response.status,
                message: error.describe(response.status, body),
                body:,
                headers:,
                request_id:,
              ))
          }
        }
      }
    }
  }
}

/// Logs go to the Erlang logger, whose level decides what is output. `Info`
/// logs one summary line per attempt; `Debug` adds request headers, with
/// credentials redacted, and bodies, unredacted.
fn log_lazy(level: LogLevel, message: fn() -> String) -> Nil {
  case logging.allows(level) {
    True -> logging.log(level, "[typesafe-sdk] " <> message())
    False -> Nil
  }
}

/// `headers` with credential values masked, keeping a key's scheme and the
/// last four characters of secrets longer than eight.
fn redact_headers(headers: List(#(String, String))) -> List(#(String, String)) {
  list.map(headers, fn(header) {
    let #(name, value) = header
    case name {
      "authorization" | "proxy-authorization" | "x-api-key" -> #(
        name,
        redact_key(value),
      )
      "cookie" -> #(name, "***")
      _ -> header
    }
  })
}

fn redact_key(value: String) -> String {
  let #(scheme, secret) = case string.split_once(string.trim(value), " ") {
    Ok(#(scheme, secret)) -> #(scheme <> " ", string.trim(secret))
    Error(Nil) -> #("", value)
  }
  let tail = case string.length(secret) > 8 {
    True -> string.slice(secret, -4, 4)
    False -> ""
  }
  scheme <> "***" <> tail
}

fn describe_body(body: BitArray) -> String {
  case bit_array.to_string(body) {
    Ok(text) -> text
    Error(Nil) -> int.to_string(bit_array.byte_size(body)) <> " bytes"
  }
}

/// `body` as text, with each invalid UTF-8 byte replaced by U+FFFD.
fn body_text(body: BitArray) -> String {
  case bit_array.to_string(body) {
    Ok(text) -> text
    Error(Nil) -> lossy_utf8(body, "")
  }
}

fn lossy_utf8(bytes: BitArray, text: String) -> String {
  case bytes {
    <<>> -> text
    <<char:utf8_codepoint, rest:bits>> ->
      lossy_utf8(rest, text <> string.from_utf_codepoints([char]))
    <<_, rest:bits>> -> lossy_utf8(rest, text <> "\u{FFFD}")
    _ -> text <> "\u{FFFD}"
  }
}

fn httpc_transport(
  http_request: Request(BitArray),
  timeout_ms: Int,
) -> Result(Response(BitArray), TransportError) {
  httpc.configure()
  |> httpc.timeout(timeout_ms)
  |> httpc.dispatch_bits(http_request)
  |> result.map_error(fn(error) {
    case error {
      httpc.ResponseTimeout -> TransportTimeout
      _ -> TransportFailed(string.inspect(error))
    }
  })
}

@external(erlang, "typesafe_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "typesafe_ffi", "has_zstd")
fn has_zstd() -> Bool

@external(erlang, "typesafe_ffi", "zstd_compress")
fn zstd_compress(data: BitArray) -> BitArray

@external(erlang, "typesafe_ffi", "random_hex")
fn random_hex() -> String

@external(erlang, "typesafe_ffi", "sleep")
fn sleep(ms: Int) -> Nil

@external(erlang, "typesafe_ffi", "system_time_ms")
fn system_time_ms() -> Int

@external(erlang, "typesafe_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

@external(erlang, "typesafe_ffi", "unique_id")
fn unique_id() -> Int

@external(erlang, "typesafe_ffi", "runtime")
fn runtime() -> String
