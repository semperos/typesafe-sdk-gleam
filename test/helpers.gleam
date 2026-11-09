import gleam/bit_array
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/result
import typesafe.{type Client, type TransportError, with_transport}
import typesafe/logging.{type LogLevel}

pub type Ref

/// A request as the transport received it.
pub type Sent {
  Sent(request: Request(BitArray), timeout_ms: Int)
}

/// A transport that answers each request with `respond`, recording what it
/// receives. Every helper here runs in the calling test's process.
pub fn mock(
  client: Client,
  respond: fn(Int) -> Result(Response(BitArray), TransportError),
) -> #(Client, fn() -> List(Sent)) {
  let store = new_ref()
  let transport = fn(req, timeout_ms) {
    let index = list.length(values(store))
    append(store, Sent(req, timeout_ms))
    respond(index)
  }
  #(with_transport(client, transport), fn() { values(store) })
}

/// Answer the nth request with the nth response, repeating the last.
pub fn sequence(
  responses: List(Result(Response(BitArray), TransportError)),
) -> fn(Int) -> Result(Response(BitArray), TransportError) {
  fn(index) {
    let assert Ok(last) = list.last(responses)
    list.drop(responses, index) |> list.first |> result.unwrap(last)
  }
}

pub fn always(
  response: Result(Response(BitArray), TransportError),
) -> fn(Int) -> Result(Response(BitArray), TransportError) {
  fn(_) { response }
}

pub fn json_response(status: Int, body: String) -> Response(BitArray) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(bit_array.from_string(body))
}

/// Run `run` with the Erlang logger at `level`, returning its result and
/// the lines the SDK logged.
@external(erlang, "helpers_ffi", "capture_logs")
pub fn capture_logs(
  level: LogLevel,
  run: fn() -> a,
) -> #(a, List(#(LogLevel, String)))

/// Keep SDK logs out of the test output.
@external(erlang, "helpers_ffi", "remove_default_handler")
pub fn remove_default_handler() -> Nil

/// The request body as it was before compression.
pub fn body(req: Request(BitArray)) -> BitArray {
  case request.get_header(req, "content-encoding") {
    Ok("zstd") -> zstd_decompress(req.body)
    _ -> req.body
  }
}

pub fn body_text(req: Request(BitArray)) -> String {
  let assert Ok(text) = bit_array.to_string(body(req))
  text
}

/// A part of a `multipart/form-data` body: its header lines and content.
pub type Part {
  Part(headers: String, content: BitArray)
}

pub fn parts(req: Request(BitArray)) -> List(Part) {
  let assert Ok("multipart/form-data; boundary=" <> boundary) =
    request.get_header(req, "content-type")
  let assert [<<>>, ..sections] =
    split(body(req), bit_array.from_string("--" <> boundary))
  let #(sections, closing) = list.split(sections, list.length(sections) - 1)
  let assert [<<"--\r\n">>] = closing
  list.map(sections, fn(section) {
    let assert Ok(#(<<"\r\n", head:bits>>, rest)) =
      split_once(section, <<"\r\n\r\n">>)
    let size = bit_array.byte_size(rest) - 2
    let assert <<content:bytes-size(size), "\r\n">> = rest
    let assert Ok(head) = bit_array.to_string(head)
    Part(headers: head, content:)
  })
}

/// The JSON request payload, from a JSON body or a multipart `request` part.
pub fn payload(req: Request(BitArray)) -> String {
  case request.get_header(req, "content-type") {
    Ok("multipart/form-data" <> _) -> {
      let assert [Part(content:, ..), ..] = parts(req)
      let assert Ok(text) = bit_array.to_string(content)
      text
    }
    _ -> body_text(req)
  }
}

@external(erlang, "helpers_ffi", "new_ref")
fn new_ref() -> Ref

@external(erlang, "helpers_ffi", "append")
fn append(ref: Ref, value: a) -> Nil

@external(erlang, "helpers_ffi", "values")
fn values(ref: Ref) -> List(a)

@external(erlang, "helpers_ffi", "zstd_decompress")
fn zstd_decompress(data: BitArray) -> BitArray

@external(erlang, "helpers_ffi", "split")
fn split(data: BitArray, separator: BitArray) -> List(BitArray)

@external(erlang, "helpers_ffi", "split_once")
fn split_once(
  data: BitArray,
  separator: BitArray,
) -> Result(#(BitArray, BitArray), Nil)

@external(erlang, "helpers_ffi", "put_env")
pub fn put_env(name: String, value: String) -> Nil

@external(erlang, "helpers_ffi", "unset_env")
pub fn unset_env(name: String) -> Nil

/// The version in `gleam.toml`, as the compiled application reports it.
@external(erlang, "helpers_ffi", "package_version")
pub fn package_version() -> String
