import gleam/bit_array
import gleam/dict
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import helpers.{type Sent, Part, Sent, always, json_response, mock}
import typesafe.{
  ModelCard, NoCompression, SystemOneRequest, SystemOneResult, TransportFailed,
  Usage,
}
import typesafe/content.{
  Array, Asset, Bool, Embed, Float, Int, Literal, Null, Object, String, Text,
}
import typesafe/error.{
  ConnectionError, InvalidConfig, InvalidRequest, UnexpectedResponse,
}
import typesafe/question.{
  Box, BoxAnswer, BoxCoordinates, Choice, ChoiceAnswer, Noul, NoulAnswer, Score,
  ScoreAnswer,
}
import typesafe/retry

pub fn main() -> Nil {
  helpers.remove_default_handler()
  gleeunit.main()
}

const key = "sk-test-0123456789"

const noul_answer =
  "{\"model\":\"jev-latest\",\"answers\":{\"q\":{\"type\":\"noul\",\"noul\":0.9}},\"usage\":{\"input_tokens\":12,\"output_tokens\":1}}"

const models =
  "{\"models\":[{\"name\":\"jev-latest\",\"description\":\"d\",\"release_date\":\"2026-01-01\",\"internal\":true}]}"

fn client() {
  mock(typesafe.new(key), always(Ok(json_response(200, noul_answer))))
}

fn ask(state) {
  typesafe.system_one_request(state, [
    #("q", question.noul(String("Is it?"))),
  ])
}

/// The one request sent, failing the test if there were more or none.
fn sent_request(sent: fn() -> List(Sent)) -> Request(BitArray) {
  let assert [Sent(request:, ..)] = sent()
  request
}

/// Send `request` and return the payload the API received.
fn payload_of(request) -> String {
  let #(client, sent) = client()
  let assert Ok(_) = typesafe.system_one(client, request)
  helpers.payload(sent_request(sent))
}

const env_vars = [
  "TYPESAFE_API_KEY", "TYPESAFE_BASE_URL", "TYPESAFE_DEFAULT_MODEL",
]

fn with_env(vars: List(#(String, String)), run: fn() -> a) -> a {
  list.each(env_vars, helpers.unset_env)
  list.each(vars, fn(var) { helpers.put_env(var.0, var.1) })
  let result = run()
  list.each(env_vars, helpers.unset_env)
  result
}

/// Send a request through a client from `from_env` and return it.
fn sent_from_env() -> Request(BitArray) {
  let assert Ok(client) = typesafe.from_env()
  let #(client, sent) =
    mock(client, always(Ok(json_response(200, noul_answer))))
  let assert Ok(_) = typesafe.system_one(client, ask(String("x")))
  sent_request(sent)
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub fn from_env_falls_back_to_defaults_test() {
  use <- with_env([#("TYPESAFE_API_KEY", key)])
  let req = sent_from_env()
  assert request.to_uri(req).host == Some("api.typesafe.ai")
  assert req.scheme == http.Https
  assert req.path == "/v1/systemone"
  assert string.contains(helpers.payload(req), "\"model\":\"jev-latest\"")
  assert request.get_header(req, "authorization") == Ok("Bearer " <> key)
}

pub fn from_env_reads_every_setting_test() {
  use <- with_env([
    #("TYPESAFE_API_KEY", " env-key "),
    #("TYPESAFE_BASE_URL", "http://localhost:8080//"),
    #("TYPESAFE_DEFAULT_MODEL", "jev-env"),
  ])
  let req = sent_from_env()
  assert request.to_uri(req).host == Some("localhost")
  assert req.port == Some(8080)
  assert req.path == "/v1/systemone"
  assert string.contains(helpers.payload(req), "\"model\":\"jev-env\"")
  assert request.get_header(req, "authorization") == Ok("Bearer env-key")
}

pub fn explicit_settings_override_the_environment_test() {
  use <- with_env([
    #("TYPESAFE_API_KEY", "env-key"),
    #("TYPESAFE_DEFAULT_MODEL", "jev-env"),
  ])
  let assert Ok(client) = typesafe.from_env()
  let #(client, sent) =
    client
    |> typesafe.with_default_model("jev-code")
    |> typesafe.with_base_url("https://example.test/")
    |> mock(always(Ok(json_response(200, noul_answer))))
  let assert Ok(_) = typesafe.system_one(client, ask(String("x")))
  let req = sent_request(sent)
  assert request.to_uri(req).host == Some("example.test")
  assert string.contains(helpers.payload(req), "\"model\":\"jev-code\"")
}

pub fn blank_environment_values_count_as_unset_test() {
  use <- with_env([
    #("TYPESAFE_API_KEY", key),
    #("TYPESAFE_BASE_URL", "   "),
    #("TYPESAFE_DEFAULT_MODEL", ""),
  ])
  let req = sent_from_env()
  assert request.to_uri(req).host == Some("api.typesafe.ai")
  assert string.contains(helpers.payload(req), "\"model\":\"jev-latest\"")
}

pub fn from_env_requires_an_api_key_test() {
  use <- with_env([#("TYPESAFE_API_KEY", " ")])
  assert typesafe.from_env()
    == Error(InvalidConfig(
      "No API key was provided. Pass one to `new` or set the TYPESAFE_API_KEY environment variable.",
    ))
}

pub fn strips_trailing_slashes_from_the_base_url_test() {
  let #(client, sent) = client()
  let client = typesafe.with_base_url(client, "https://x.test/api///")
  let assert Ok(_) = typesafe.system_one(client, ask(String("x")))
  assert sent_request(sent).path == "/api/v1/systemone"
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

pub fn sends_auth_and_identifying_headers_test() {
  let #(client, sent) = client()
  let assert Ok(_) = typesafe.system_one(client, ask(String("x")))
  let req = sent_request(sent)
  assert req.method == http.Post
  assert request.get_header(req, "authorization") == Ok("Bearer " <> key)
  assert request.get_header(req, "accept") == Ok("application/json")
  assert request.get_header(req, "content-type") == Ok("application/json")
  assert request.get_header(req, "user-agent") == Ok("typesafe-sdk-gleam/1.0.0")
  assert request.get_header(req, "x-typesafe-sdk")
    == Ok("typesafe-sdk-gleam/1.0.0")
  let assert Ok("erlang/" <> _) = request.get_header(req, "x-typesafe-runtime")
  assert request.get_header(req, "x-typesafe-retry-count") == Error(Nil)
}

pub fn client_headers_never_clobber_sdk_headers_test() {
  let #(client, sent) = client()
  let client =
    client
    |> typesafe.with_header("X-Trace", "one")
    |> typesafe.with_header("x-trace", "two")
    |> typesafe.with_header("Authorization", "Bearer stolen")
    |> typesafe.with_header("Content-Type", "text/plain")
    |> typesafe.with_header("X-TypeSafe-Retry-Count", "9")
  let assert Ok(_) = typesafe.system_one(client, ask(String("x")))
  let req = sent_request(sent)
  let named = fn(name) {
    list.filter(req.headers, fn(header) { header.0 == name })
  }
  assert named("x-trace") == [#("x-trace", "two")]
  assert named("authorization") == [#("authorization", "Bearer " <> key)]
  assert named("content-type") == [#("content-type", "application/json")]
  assert named("x-typesafe-retry-count") == []
}

pub fn get_requests_send_no_content_type_test() {
  let #(client, sent) =
    mock(typesafe.new(key), always(Ok(json_response(200, models))))
  let client = typesafe.with_header(client, "content-type", "a/b")
  let assert Ok(_) = typesafe.list_models(client)
  let req = sent_request(sent)
  assert req.method == http.Get
  assert req.path == "/v1/models"
  assert request.get_header(req, "content-type") == Error(Nil)
  assert req.body == <<>>
}

pub fn lists_models_test() {
  let #(client, _) =
    mock(typesafe.new(key), always(Ok(json_response(200, models))))
  assert typesafe.list_models(client)
    == Ok([ModelCard("jev-latest", "d", "2026-01-01")])
}

pub fn rejects_an_unexpected_models_response_test() {
  let #(client, _) =
    mock(typesafe.new(key), always(Ok(json_response(200, "{\"cards\":[]}"))))
  assert typesafe.list_models(client)
    == Error(UnexpectedResponse(
      "Unexpected response shape from GET /v1/models.",
      "{\"cards\":[]}",
    ))
}

pub fn send_gives_raw_access_to_the_response_test() {
  let #(client, _) =
    mock(
      typesafe.new(key),
      always(Ok(
        json_response(200, models)
        |> response.prepend_header("X-TypeSafe-Request-Id", "req_1"),
      )),
    )
  let assert Ok(req) = typesafe.build_list_models(client)
  let assert Ok(response) = typesafe.send(client, req)
  assert response.status == 200
  assert response.body == bit_array.from_string(models)
  assert list.key_find(response.headers, "x-typesafe-request-id") == Ok("req_1")
}

pub fn posts_the_payload_with_the_default_model_test() {
  assert payload_of(ask(String("I was charged twice.")))
    == "{\"state\":\"I was charged twice.\",\"questions\":{\"q\":{\"type\":\"noul\",\"instructions\":\"Is it?\"}},\"model\":\"jev-latest\"}"
}

pub fn honors_the_per_request_and_client_model_test() {
  assert payload_of(SystemOneRequest(..ask(Int(1)), model: Some("jev-preview")))
    |> string.contains("\"model\":\"jev-preview\"")
  let #(client, sent) = client()
  let client = typesafe.with_default_model(client, "jev-2")
  let assert Ok(_) = typesafe.system_one(client, ask(Int(1)))
  assert helpers.payload(sent_request(sent))
    |> string.contains("\"model\":\"jev-2\"")
}

pub fn decodes_answers_and_usage_test() {
  let #(client, _) = client()
  assert typesafe.system_one(client, ask(String("x")))
    == Ok(SystemOneResult(
      model: "jev-latest",
      answers: dict.from_list([#("q", NoulAnswer(0.9))]),
      usage: Usage(Some(12), Some(1)),
    ))
}

pub fn wraps_network_failures_test() {
  let #(client, _) =
    mock(typesafe.new(key), always(Error(TransportFailed("nxdomain"))))
  let client =
    typesafe.with_retry(
      client,
      retry.RetryPolicy(..retry.default_policy(), max_retries: 0),
    )
  assert typesafe.system_one(client, ask(String("x")))
    == Error(ConnectionError("Connection error: nxdomain"))
}

// ---------------------------------------------------------------------------
// Compression
// ---------------------------------------------------------------------------

fn sent_with_state(client, state) -> Request(BitArray) {
  let #(client, sent) =
    mock(client, always(Ok(json_response(200, noul_answer))))
  let assert Ok(_) = typesafe.system_one(client, ask(String(state)))
  sent_request(sent)
}

pub fn compresses_bodies_of_at_least_1_kib_with_zstd_test() {
  let state = string.repeat("a", 2000)
  let req = sent_with_state(typesafe.new(key), state)
  assert request.get_header(req, "content-encoding") == Ok("zstd")
  assert bit_array.byte_size(req.body) < 1000
  assert string.contains(helpers.body_text(req), state)
}

pub fn sends_bodies_under_1_kib_uncompressed_test() {
  let req = sent_with_state(typesafe.new(key), "short")
  assert request.get_header(req, "content-encoding") == Error(Nil)
  assert string.contains(helpers.body_text(req), "\"short\"")
}

pub fn measures_the_body_in_utf8_bytes_test() {
  // 400 three-byte characters: under 1 KiB as characters, over it as bytes.
  let req = sent_with_state(typesafe.new(key), string.repeat("€", 400))
  assert request.get_header(req, "content-encoding") == Ok("zstd")
}

pub fn no_compression_sends_bodies_as_is_and_drops_a_callers_encoding_test() {
  let client =
    typesafe.new(key)
    |> typesafe.with_compression(NoCompression)
    |> typesafe.with_header("content-encoding", "gzip")
  let state = string.repeat("a", 2000)
  let req = sent_with_state(client, state)
  assert request.get_header(req, "content-encoding") == Error(Nil)
  let assert Ok(text) = bit_array.to_string(req.body)
  assert string.contains(text, state)
}

pub fn replaces_a_callers_encoding_with_the_one_used_test() {
  let client =
    typesafe.new(key)
    |> typesafe.with_header("Content-Encoding", "br")
  let req = sent_with_state(client, string.repeat("a", 2000))
  let encodings =
    list.filter(req.headers, fn(header) { header.0 == "content-encoding" })
  assert encodings == [#("content-encoding", "zstd")]
}

// ---------------------------------------------------------------------------
// Questions and the wire format
// ---------------------------------------------------------------------------

fn questions_payload(questions) -> String {
  payload_of(typesafe.system_one_request(String("s"), questions))
}

pub fn encodes_noul_questions_test() {
  assert questions_payload([
      #("a", question.noul(String("Is it?"))),
      #("b", Noul(Null, if_true: String("yes"), if_false: Null)),
      #("c", Noul(Object([#("ask", Bool(True))]), String("y"), String("n"))),
    ])
    == "{\"state\":\"s\",\"questions\":{"
    <> "\"a\":{\"type\":\"noul\",\"instructions\":\"Is it?\"},"
    <> "\"b\":{\"type\":\"noul\",\"instructions\":null,\"criteria\":{\"true\":\"yes\"}},"
    <> "\"c\":{\"type\":\"noul\",\"instructions\":{\"ask\":true},\"criteria\":{\"true\":\"y\",\"false\":\"n\"}}"
    <> "},\"model\":\"jev-latest\"}"
}

pub fn encodes_choice_score_and_box_questions_test() {
  assert questions_payload([
      #(
        "tone",
        Choice(String("Tone?"), [#("calm", Null), #("angry", String("Upset"))]),
      ),
      #("rank", Score(Null, [Null, Array([Int(1), Float(0.5)]), String("Top")])),
      #("dog", Box(String("The dog"))),
    ])
    == "{\"state\":\"s\",\"questions\":{"
    <> "\"tone\":{\"type\":\"choice\",\"instructions\":\"Tone?\",\"criteria\":{\"calm\":null,\"angry\":\"Upset\"}},"
    <> "\"rank\":{\"type\":\"score\",\"instructions\":null,\"criteria\":[null,[1,0.5],\"Top\"]},"
    <> "\"dog\":{\"type\":\"box\",\"instructions\":\"The dog\"}"
    <> "},\"model\":\"jev-latest\"}"
}

fn rejected(request) {
  let #(client, sent) = client()
  let result = typesafe.system_one(client, request)
  assert sent() == []
  result
}

pub fn rejects_invalid_questions_before_sending_test() {
  let with = fn(questions) {
    rejected(typesafe.system_one_request(String("s"), questions))
  }
  assert with([]) == Error(InvalidRequest("At least one question is required."))
  assert with([#("r", Score(Null, [String("only")]))])
    == Error(InvalidRequest(
      "Score question \"r\" has 1 criteria; at least two scores are required.",
    ))
  assert with([#("c", Choice(String("?"), []))])
    == Error(InvalidRequest(
      "Choice question \"c\" has no criteria; at least one choice is required.",
    ))
  assert with([#("n", Noul(Null, Null, Null))])
    == Error(InvalidRequest(
      "Noul question \"n\" has neither instructions nor criteria; at least one is required.",
    ))
  assert with([#("x", Box(Null)), #("x", Box(Null))])
    == Error(InvalidRequest("Question names must be unique."))
}

pub fn rejects_null_state_before_sending_test() {
  assert rejected(ask(Null)) == Error(InvalidRequest("State is required."))
}

fn answers(body: String) {
  let #(client, _) =
    mock(typesafe.new(key), always(Ok(json_response(200, body))))
  let assert Ok(result) = typesafe.system_one(client, ask(Int(1)))
  result.answers
}

pub fn decodes_choice_answers_test() {
  assert answers(
      "{\"model\":\"m\",\"answers\":{\"t\":{\"type\":\"choice\",\"choice\":\"calm\",\"confidence\":0.8,\"probabilities\":{\"calm\":0.8,\"angry\":0.2}}}}",
    )
    == dict.from_list([
      #(
        "t",
        ChoiceAnswer(
          "calm",
          0.8,
          dict.from_list([#("calm", 0.8), #("angry", 0.2)]),
        ),
      ),
    ])
}

pub fn decodes_score_answers_test() {
  assert answers(
      "{\"model\":\"m\",\"answers\":{\"r\":{\"type\":\"score\",\"score\":1.5,\"confidence\":1,\"legend\":{\"0\":null,\"1\":\"Mid\",\"2\":{\"k\":[true]}},\"probabilities\":{\"0\":0,\"1\":0.5,\"2\":0.5}}}}",
    )
    == dict.from_list([
      #(
        "r",
        ScoreAnswer(
          1.5,
          1.0,
          dict.from_list([
            #(0, Null),
            #(1, String("Mid")),
            #(2, Object([#("k", Array([Bool(True)]))])),
          ]),
          dict.from_list([#(0, 0.0), #(1, 0.5), #(2, 0.5)]),
        ),
      ),
    ])
}

pub fn decodes_box_answers_with_and_without_confidence_test() {
  let box = "\"box\":{\"top\":0.1,\"bottom\":0.9,\"left\":0,\"right\":1}"
  assert answers(
      "{\"model\":\"m\",\"answers\":{\"a\":{\"type\":\"box\","
      <> box
      <> ",\"confidence\":0.7,\"extra\":1},\"b\":{\"type\":\"box\","
      <> box
      <> ",\"confidence\":null}}}",
    )
    == dict.from_list([
      #("a", BoxAnswer(BoxCoordinates(0.1, 0.9, 0.0, 1.0), Some(0.7))),
      #("b", BoxAnswer(BoxCoordinates(0.1, 0.9, 0.0, 1.0), None)),
    ])
}

// ---------------------------------------------------------------------------
// Image assets
// ---------------------------------------------------------------------------

const png_header = <<0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a>>

fn png(tail: BitArray) {
  let assert Ok(image) = content.image(<<png_header:bits, tail:bits>>)
  image
}

fn reference(bytes: BitArray) -> String {
  "<image:" <> string.lowercase(bit_array.base16_encode(md5(bytes))) <> ">"
}

@external(erlang, "erlang", "md5")
fn md5(data: BitArray) -> BitArray

fn sent_parts(request) {
  let #(client, sent) = client()
  let assert Ok(_) = typesafe.system_one(client, request)
  helpers.parts(sent_request(sent))
}

pub fn sends_named_assets_as_multipart_parts_test() {
  let photo = png(<<1>>)
  let request =
    SystemOneRequest(
      ..typesafe.system_one_request(String("See <photo>"), [
        #("q", question.noul(String("Damaged?"))),
      ]),
      assets: [#("<photo>", photo)],
    )
  let assert [Part(request_headers, request_json), Part(image_headers, bytes)] =
    sent_parts(request)
  assert request_headers
    == "Content-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json"
  assert request_json
    == bit_array.from_string(
      "{\"state\":\"See <photo>\",\"questions\":{\"q\":{\"type\":\"noul\",\"instructions\":\"Damaged?\"}},\"model\":\"jev-latest\",\"assets\":{\"<photo>\":{\"type\":\"image\",\"part\":\"asset-0\"}}}",
    )
  assert image_headers
    == "Content-Disposition: form-data; name=\"asset-0\"; filename=\"asset-0\"\r\nContent-Type: image/png"
  assert bytes == <<png_header:bits, 1>>
}

pub fn sends_images_in_content_under_their_references_test() {
  let photo = png(<<1>>)
  let jpeg_bytes = <<0xff, 0xd8, 0xff, 2>>
  let assert Ok(jpeg) = content.image(jpeg_bytes)
  let request =
    typesafe.system_one_request(Array([Asset(photo), Asset(photo)]), [
      #(
        "same",
        question.noul(
          Text([Literal("Is "), Embed(photo), Literal(" "), Embed(jpeg)]),
        ),
      ),
    ])
  let photo_ref = reference(<<png_header:bits, 1>>)
  let jpeg_ref = reference(jpeg_bytes)
  let assert [
    Part(_, request_json),
    Part(png_headers, _),
    Part(jpeg_headers, _),
  ] = sent_parts(request)
  assert request_json
    == bit_array.from_string(
      "{\"state\":[\""
      <> photo_ref
      <> "\",\""
      <> photo_ref
      <> "\"],\"questions\":{\"same\":{\"type\":\"noul\",\"instructions\":\"Is "
      <> photo_ref
      <> " "
      <> jpeg_ref
      <> "\"}},\"model\":\"jev-latest\",\"assets\":{\""
      <> photo_ref
      <> "\":{\"type\":\"image\",\"part\":\"asset-0\"},\""
      <> jpeg_ref
      <> "\":{\"type\":\"image\",\"part\":\"asset-1\"}}}",
    )
  assert string.ends_with(png_headers, "Content-Type: image/png")
  assert string.ends_with(jpeg_headers, "Content-Type: image/jpeg")
}

pub fn writes_a_named_image_as_its_last_name_and_sends_it_per_name_test() {
  let photo = png(<<1>>)
  let request =
    SystemOneRequest(
      ..typesafe.system_one_request(Text([Literal("<a> is "), Embed(photo)]), [
        #("q", question.noul(Asset(photo))),
      ]),
      assets: [#("<a>", photo), #("<b>", photo)],
    )
  let assert [Part(_, request_json), Part(first, one), Part(second, two)] =
    sent_parts(request)
  assert request_json
    == bit_array.from_string(
      "{\"state\":\"<a> is <b>\",\"questions\":{\"q\":{\"type\":\"noul\",\"instructions\":\"<b>\"}},\"model\":\"jev-latest\",\"assets\":{\"<a>\":{\"type\":\"image\",\"part\":\"asset-0\"},\"<b>\":{\"type\":\"image\",\"part\":\"asset-1\"}}}",
    )
  assert string.contains(first, "name=\"asset-0\"")
  assert string.contains(second, "name=\"asset-1\"")
  assert one == <<png_header:bits, 1>>
  assert two == one
}

pub fn rejects_names_missing_from_the_request_before_sending_test() {
  let request =
    SystemOneRequest(..ask(String("no names here")), assets: [
      #("<photo>", png(<<1>>)),
      #("<logo>", png(<<2>>)),
    ])
  assert rejected(request)
    == Error(InvalidRequest(
      "Assets not referenced in the request: <photo>, <logo>. Write each name in `assets` into the state, question instructions, or criteria.",
    ))
}

pub fn matches_names_as_escaped_in_the_json_test() {
  let request =
    SystemOneRequest(..ask(String("see \"photo\"")), assets: [
      #("\"photo\"", png(<<1>>)),
    ])
  let assert [_, _] = sent_parts(request)
}

pub fn sends_unrecognized_formats_as_octet_stream_test() {
  let assert Ok(gif) = content.image(<<"GIF89a":utf8>>)
  let assert [_, Part(headers, bytes)] = sent_parts(ask(Asset(gif)))
  assert string.ends_with(headers, "Content-Type: application/octet-stream")
  assert bytes == <<"GIF89a":utf8>>
}

pub fn compresses_multipart_bodies_test() {
  let large = png(<<0:size(16_000)>>)
  let #(client, sent) = client()
  let assert Ok(_) = typesafe.system_one(client, ask(Asset(large)))
  let req = sent_request(sent)
  assert request.get_header(req, "content-encoding") == Ok("zstd")
  let assert [_, Part(_, bytes)] = helpers.parts(req)
  assert bytes == <<png_header:bits, 0:size(16_000)>>
}

pub fn decodes_base64_images_test() {
  let assert Ok(photo) = content.image_from_base64("iVBORw0KGgoB")
  let assert [_, Part(_, bytes)] = sent_parts(ask(Asset(photo)))
  assert bytes == <<png_header:bits, 1>>
}

pub fn rejects_invalid_or_empty_image_data_test() {
  assert content.image_from_base64("not base64!")
    == Error(InvalidRequest("Image data must contain valid base64 text."))
  assert content.image_from_base64("")
    == Error(InvalidRequest("Image data is empty."))
  assert content.image(<<>>) == Error(InvalidRequest("Image data is empty."))
}

pub fn rejects_duplicate_asset_names_and_choice_labels_test() {
  assert rejected(
      SystemOneRequest(..ask(String("<p> and <p>")), assets: [
        #("<p>", png(<<1>>)),
        #("<p>", png(<<2>>)),
      ]),
    )
    == Error(InvalidRequest("Asset names must be unique."))
  assert rejected(
      typesafe.system_one_request(String("s"), [
        #("t", Choice(Null, [#("a", Null), #("a", String("again"))])),
      ]),
    )
    == Error(InvalidRequest("Choice question \"t\" has duplicate labels."))
}

pub fn treats_null_usage_as_unreported_test() {
  let #(client, _) =
    mock(
      typesafe.new(key),
      always(
        Ok(json_response(200, "{\"model\":\"m\",\"answers\":{},\"usage\":null}")),
      ),
    )
  let assert Ok(SystemOneResult(usage: Usage(None, None), ..)) =
    typesafe.system_one(client, ask(String("x")))
}
