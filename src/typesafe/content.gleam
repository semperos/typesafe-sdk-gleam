import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/string
import typesafe/error.{type Error, InvalidRequest}

/// A JSON-compatible value that may also hold image assets, used for request
/// state, question instructions, and criteria.
pub type Content {
  String(String)
  Int(Int)
  Float(Float)
  Bool(Bool)
  Null
  Array(List(Content))
  Object(List(#(String, Content)))
  /// An image, sent with the request and written in the JSON as its name in
  /// the request's `assets`, or else as its reference.
  Asset(Image)
  /// Text with images embedded in it, each written the same way as `Asset`.
  Text(List(Piece))
}

/// A run of `Text` content.
pub type Piece {
  Literal(String)
  Embed(Image)
}

/// A PNG or JPEG image. The API detects the format from the file bytes and
/// rejects other formats with a 400 `ApiError`.
pub opaque type Image {
  Image(bytes: BitArray, reference: String)
}

/// An image from its file bytes.
pub fn image(bytes: BitArray) -> Result(Image, Error) {
  case bytes {
    <<>> -> Error(InvalidRequest("Image data is empty."))
    _ -> Ok(Image(bytes:, reference: "<image:" <> md5_hex(bytes) <> ">"))
  }
}

/// An image from base64-encoded file bytes, without a `data:` URL prefix.
pub fn image_from_base64(text: String) -> Result(Image, Error) {
  case bit_array.base64_decode(text) {
    Ok(bytes) -> image(bytes)
    Error(Nil) ->
      Error(InvalidRequest("Image data must contain valid base64 text."))
  }
}

/// A request payload serialized to JSON, with the assets it sends in order.
pub type Serialized {
  Serialized(fields: List(#(String, Json)), assets: List(#(String, Image)))
}

/// Serialize `fields`, writing each image as its name in `named`, or else as
/// its reference. The assets sent are those in `named`, then each other
/// image in order of first appearance.
pub fn serialize(
  fields: List(#(String, Content)),
  named: List(#(String, Image)),
) -> Result(Serialized, Error) {
  // An image under several names is written as the last one.
  let names = dict.from_list(list.map(named, fn(entry) { #(entry.1, entry.0) }))
  let #(encoded, found) =
    list.map_fold(fields, [], fn(found, field) {
      let #(json, found) = encode(field.1, names, found)
      #(found, #(field.0, json))
    })
    |> swap
  let text = json.to_string(json.object(encoded))
  let unreferenced =
    list.filter(named, fn(entry) {
      let escaped = json.to_string(json.string(entry.0))
      !string.contains(
        text,
        string.slice(escaped, 1, string.length(escaped) - 2),
      )
    })
  let names = list.map(named, fn(entry) { entry.0 })
  case unreferenced, list.length(list.unique(names)) == list.length(names) {
    _, False -> Error(InvalidRequest("Asset names must be unique."))
    [], True -> {
      let unnamed =
        list.reverse(found) |> list.map(fn(image) { #(image.reference, image) })
      Ok(Serialized(fields: encoded, assets: list.append(named, unnamed)))
    }
    _, True ->
      Error(InvalidRequest(
        "Assets not referenced in the request: "
        <> string.join(list.map(unreferenced, fn(entry) { entry.0 }), ", ")
        <> ". Write each name in `assets` into the state, question instructions, or criteria.",
      ))
  }
}

fn swap(pair: #(a, b)) -> #(b, a) {
  #(pair.1, pair.0)
}

/// `content` as JSON, writing each image as its reference. Meant for content
/// without images, such as an answer's legend.
pub fn to_json(content: Content) -> Json {
  encode(content, dict.new(), []).0
}

/// `content` as JSON, with unnamed images prepended to `found` once each.
fn encode(
  content: Content,
  names: Dict(Image, String),
  found: List(Image),
) -> #(Json, List(Image)) {
  case content {
    String(text) -> #(json.string(text), found)
    Int(n) -> #(json.int(n), found)
    Float(n) -> #(json.float(n), found)
    Bool(b) -> #(json.bool(b), found)
    Null -> #(json.null(), found)
    Array(items) -> {
      let #(found, items) =
        list.map_fold(items, found, fn(found, item) {
          encode(item, names, found) |> swap
        })
      #(json.preprocessed_array(items), found)
    }
    Object(entries) -> {
      let #(found, entries) =
        list.map_fold(entries, found, fn(found, entry) {
          let #(json, found) = encode(entry.1, names, found)
          #(found, #(entry.0, json))
        })
      #(json.object(entries), found)
    }
    Asset(image) -> {
      let #(text, found) = write_image(image, names, found)
      #(json.string(text), found)
    }
    Text(pieces) -> {
      let #(found, parts) =
        list.map_fold(pieces, found, fn(found, piece) {
          case piece {
            Literal(text) -> #(found, text)
            Embed(image) -> write_image(image, names, found) |> swap
          }
        })
      #(json.string(string.concat(parts)), found)
    }
  }
}

fn write_image(
  image: Image,
  names: Dict(Image, String),
  found: List(Image),
) -> #(String, List(Image)) {
  case dict.get(names, image) {
    Ok(name) -> #(name, found)
    Error(Nil) ->
      case list.contains(found, image) {
        True -> #(image.reference, found)
        False -> #(image.reference, [image, ..found])
      }
  }
}

/// A `multipart/form-data` body (RFC 7578) whose first part, `request`, is
/// the serialized payload with an `assets` entry naming the part that holds
/// each asset's file bytes.
pub fn multipart(serialized: Serialized, boundary: String) -> BitArray {
  // The API accepts each part for only one asset, so an image under several
  // names is sent once per name.
  let parts =
    list.index_map(serialized.assets, fn(entry, index) {
      let name = "asset-" <> int.to_string(index)
      #(entry.0, name, entry.1.bytes)
    })
  let assets =
    json.object(
      list.map(parts, fn(part) {
        #(
          part.0,
          json.object([
            #("type", json.string("image")),
            #("part", json.string(part.1)),
          ]),
        )
      }),
    )
  let request =
    json.object(list.append(serialized.fields, [#("assets", assets)]))
    |> json.to_string
    |> bit_array.from_string
  let delimiter = "--" <> boundary <> "\r\n"
  let encoded_parts =
    list.map(parts, fn(part) {
      let #(_, name, bytes) = part
      <<
        delimiter:utf8,
        "Content-Disposition: form-data; name=\"":utf8,
        name:utf8,
        "\"; filename=\"":utf8,
        name:utf8,
        "\"\r\nContent-Type: ":utf8,
        content_type(bytes):utf8,
        "\r\n\r\n":utf8,
        bytes:bits,
        "\r\n":utf8,
      >>
    })
  bit_array.concat([
    <<
      delimiter:utf8,
      "Content-Disposition: form-data; name=\"request\"\r\n":utf8,
      "Content-Type: application/json\r\n\r\n":utf8,
      request:bits,
      "\r\n":utf8,
    >>,
    ..list.append(encoded_parts, [<<"--":utf8, boundary:utf8, "--\r\n":utf8>>])
  ])
}

/// The content type whose file signature `bytes` start with (PNG spec §5.2,
/// the ITU T.81 SOI marker), or `application/octet-stream`.
fn content_type(bytes: BitArray) -> String {
  case bytes {
    <<0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, _:bits>> -> "image/png"
    <<0xff, 0xd8, 0xff, _:bits>> -> "image/jpeg"
    _ -> "application/octet-stream"
  }
}

/// Decode a plain JSON value, as the API returns content.
pub fn decoder() -> decode.Decoder(Content) {
  use <- decode.recursive
  decode.one_of(decode.string |> decode.map(String), [
    decode.int |> decode.map(Int),
    decode.float |> decode.map(Float),
    decode.bool |> decode.map(Bool),
    decode.list(decoder()) |> decode.map(Array),
    decode.dict(decode.string, decoder())
      |> decode.map(fn(entries) { Object(dict.to_list(entries)) }),
    decode.optional(decode.failure(Null, "null")) |> decode.map(fn(_) { Null }),
  ])
}

@external(erlang, "typesafe_ffi", "md5_hex")
fn md5_hex(data: BitArray) -> String
