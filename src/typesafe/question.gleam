import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import typesafe/content.{type Content, Array, Null, Object, String}
import typesafe/error.{type Error, InvalidRequest}

/// A question about the request's state. `Null` content leaves instructions
/// or a description out.
pub type Question {
  /// A yes/no question. Needs instructions or at least one described outcome.
  Noul(instructions: Content, if_true: Content, if_false: Content)
  /// Selects between labels, each with an optional description. Needs at
  /// least one label.
  Choice(instructions: Content, criteria: List(#(String, Content)))
  /// Scores against a rubric indexed from zero. Needs at least two levels.
  Score(instructions: Content, criteria: List(Content))
  /// Locates what the instructions describe in the request's image. Use the
  /// `jev-preview` model for box questions.
  Box(instructions: Content)
}

/// A yes/no question with no outcome descriptions.
pub fn noul(instructions: Content) -> Question {
  Noul(instructions:, if_true: Null, if_false: Null)
}

/// The answer to a question, matching its variant.
pub type Answer {
  /// The probability of yes, from 0 to 1.
  NoulAnswer(noul: Float)
  ChoiceAnswer(
    choice: String,
    confidence: Float,
    probabilities: Dict(String, Float),
  )
  /// `score` is the expected score, which may fall between rubric levels.
  /// `legend` holds each level's description as the API received it.
  ScoreAnswer(
    score: Float,
    confidence: Float,
    legend: Dict(Int, Content),
    probabilities: Dict(Int, Float),
  )
  /// `confidence` is `None` when the API didn't report it.
  BoxAnswer(box: BoxCoordinates, confidence: Option(Float))
}

/// A box's edges as fractions, from 0 to 1, of the image's height (`top`,
/// `bottom`) and width (`left`, `right`).
pub type BoxCoordinates {
  BoxCoordinates(top: Float, bottom: Float, left: Float, right: Float)
}

/// Reject an empty or ambiguous question set, or a question the API can't
/// answer.
pub fn validate(questions: List(#(String, Question))) -> Result(Nil, Error) {
  case questions {
    [] -> Error(InvalidRequest("At least one question is required."))
    _ -> {
      case unique(list.map(questions, fn(entry) { entry.0 })) {
        False -> Error(InvalidRequest("Question names must be unique."))
        True ->
          list.try_each(questions, fn(entry) { validate_one(entry.0, entry.1) })
      }
    }
  }
}

fn validate_one(name: String, question: Question) -> Result(Nil, Error) {
  let problem = case question {
    Noul(instructions: Null, if_true: Null, if_false: Null) ->
      Ok("has neither instructions nor criteria; at least one is required")
    Choice(criteria: [], ..) ->
      Ok("has no criteria; at least one choice is required")
    Choice(criteria:, ..) ->
      case unique(list.map(criteria, fn(entry) { entry.0 })) {
        True -> Error(Nil)
        False -> Ok("has duplicate labels")
      }
    Score(criteria: [] as criteria, ..)
    | Score(criteria: [_] as criteria, ..) ->
      Ok(
        "has "
        <> int.to_string(list.length(criteria))
        <> " criteria; at least two scores are required",
      )
    _ -> Error(Nil)
  }
  case problem {
    Ok(problem) ->
      Error(InvalidRequest(
        kind(question) <> " question \"" <> name <> "\" " <> problem <> ".",
      ))
    Error(Nil) -> Ok(Nil)
  }
}

fn unique(names: List(String)) -> Bool {
  list.length(list.unique(names)) == list.length(names)
}

fn kind(question: Question) -> String {
  case question {
    Noul(..) -> "Noul"
    Choice(..) -> "Choice"
    Score(..) -> "Score"
    Box(..) -> "Box"
  }
}

/// The question as request content, in the API's wire format.
pub fn to_content(question: Question) -> Content {
  case question {
    Noul(instructions:, if_true:, if_false:) -> {
      let criteria =
        [#("true", if_true), #("false", if_false)]
        |> list.filter(fn(entry) { entry.1 != Null })
      case criteria {
        [] -> wire("noul", instructions, [])
        _ -> wire("noul", instructions, [#("criteria", Object(criteria))])
      }
    }
    Choice(instructions:, criteria:) ->
      wire("choice", instructions, [#("criteria", Object(criteria))])
    Score(instructions:, criteria:) ->
      wire("score", instructions, [#("criteria", Array(criteria))])
    Box(instructions:) -> wire("box", instructions, [])
  }
}

fn wire(
  kind: String,
  instructions: Content,
  rest: List(#(String, Content)),
) -> Content {
  Object([#("type", String(kind)), #("instructions", instructions), ..rest])
}

/// Decode an answer by its `type` field.
pub fn answer_decoder() -> decode.Decoder(Answer) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "noul" -> {
      use noul <- decode.field("noul", number())
      decode.success(NoulAnswer(noul:))
    }
    "choice" -> {
      use choice <- decode.field("choice", decode.string)
      use confidence <- decode.field("confidence", number())
      use probabilities <- decode.field(
        "probabilities",
        decode.dict(decode.string, number()),
      )
      decode.success(ChoiceAnswer(choice:, confidence:, probabilities:))
    }
    "score" -> {
      use score <- decode.field("score", number())
      use confidence <- decode.field("confidence", number())
      use legend <- decode.field("legend", by_score(content.decoder()))
      use probabilities <- decode.field("probabilities", by_score(number()))
      decode.success(ScoreAnswer(score:, confidence:, legend:, probabilities:))
    }
    "box" -> {
      use box <- decode.field("box", {
        use top <- decode.field("top", number())
        use bottom <- decode.field("bottom", number())
        use left <- decode.field("left", number())
        use right <- decode.field("right", number())
        decode.success(BoxCoordinates(top:, bottom:, left:, right:))
      })
      use confidence <- decode.optional_field(
        "confidence",
        option.None,
        decode.optional(number()),
      )
      decode.success(BoxAnswer(box:, confidence:))
    }
    _ -> decode.failure(NoulAnswer(0.0), "a known answer type")
  }
}

/// A JSON number, which the API may write without a fraction.
pub fn number() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

/// An object keyed by score, decoding its keys as integers.
fn by_score(value: decode.Decoder(a)) -> decode.Decoder(Dict(Int, a)) {
  use entries <- decode.then(decode.dict(decode.string, value))
  case
    dict.to_list(entries)
    |> list.try_map(fn(entry) {
      int.parse(entry.0) |> result.map(fn(key) { #(key, entry.1) })
    })
  {
    Ok(pairs) -> decode.success(dict.from_list(pairs))
    Error(Nil) -> decode.failure(dict.new(), "an object keyed by score")
  }
}
