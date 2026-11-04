//// Tests against the live API. Run them with
////
//// ```sh
//// TYPESAFE_API_KEY=... gleam run -m live
//// ```
////
//// Set `TYPESAFE_LIVE_IMAGES=1` as well to run the image tests, for an API
//// that accepts images. `gleam test` never runs this module's tests.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import typesafe.{type Client, SystemOneRequest}
import typesafe/content.{
  type Image, Array, Asset, Embed, Literal, Null, Object, String, Text,
}
import typesafe/error.{ApiError, InvalidRequest}
import typesafe/logging
import typesafe/question.{
  type Answer, BoxAnswer, BoxCoordinates, ChoiceAnswer, NoulAnswer, ScoreAnswer,
}
import typesafe/retry

pub fn main() -> Nil {
  case typesafe.from_env() {
    Error(_) ->
      io.println("Skipped: set TYPESAFE_API_KEY to run the live tests.")
    Ok(client) -> {
      logging.configure()
      let client = typesafe.with_timeout(client, 120_000)
      let images = case get_env("TYPESAFE_LIVE_IMAGES") {
        Ok(value) if value != "" -> image_cases(client)
        _ -> []
      }
      run(list.append(cases(client), images))
    }
  }
}

fn cases(client: Client) -> List(#(String, fn() -> Nil)) {
  let ticket =
    Object([
      #("subject", String("Charged twice this month")),
      #(
        "body",
        String(
          "I see two charges of $49 on my card for August. I only have one account. Please fix this ASAP.",
        ),
      ),
    ])
  let no_retries =
    typesafe.with_retry(
      client,
      retry.RetryPolicy(..retry.default_policy(), max_retries: 0),
    )

  [
    #("lists models", fn() {
      let assert Ok(request) = typesafe.build_list_models(client)
      let assert Ok(response) = typesafe.send(client, request)
      let assert Ok(models) = typesafe.parse_list_models(response)
      let request_id = list.key_find(response.headers, "x-typesafe-request-id")
      show("GET /v1/models", #(
        request_id,
        list.length(models),
        list.first(models),
      ))
      let assert Ok(request_id) = request_id
      assert string.starts_with(request_id, "req_")
      assert models != []
    }),
    #("answers noul, choice, and score questions", fn() {
      let assert Ok(result) =
        typesafe.system_one(
          client,
          typesafe.system_one_request(ticket, [
            #(
              "isBilling",
              question.noul(String("Is this ticket about billing?")),
            ),
            #(
              "sentiment",
              question.Choice(String("What is the customer's tone?"), [
                #("calm", Null),
                #("frustrated", Null),
                #("angry", Null),
              ]),
            ),
            #(
              "urgency",
              question.Score(String("How urgent is this ticket?"), [
                String("can wait"),
                String("this week"),
                String("today"),
              ]),
            ),
          ]),
        )
      show("POST /v1/systemone", result)
      assert result.model != ""
      assert case result.usage.input_tokens {
        Some(tokens) -> tokens > 0
        None -> True
      }
      assert case result.usage.output_tokens {
        Some(tokens) -> tokens >= 0
        None -> True
      }

      let assert Ok(NoulAnswer(noul)) = dict.get(result.answers, "isBilling")
      assert noul >=. 0.0 && noul <=. 1.0

      let assert Ok(ChoiceAnswer(choice:, confidence:, probabilities:)) =
        dict.get(result.answers, "sentiment")
      assert list.contains(["angry", "calm", "frustrated"], choice)
      assert sorted_keys(probabilities) == ["angry", "calm", "frustrated"]
      assert sums_to_one(probabilities)
      assert confidence >=. 0.0

      let assert Ok(ScoreAnswer(score:, legend:, probabilities:, ..)) =
        dict.get(result.answers, "urgency")
      assert score >=. 0.0 && score <=. 2.0
      assert legend
        == dict.from_list([
          #(0, String("can wait")),
          #(1, String("this week")),
          #(2, String("today")),
        ])
      assert list.sort(dict.keys(probabilities), int.compare) == [0, 1, 2]
      assert sums_to_one(probabilities)
    }),
    #("accepts rich descriptions and one-sided noul criteria", fn() {
      let assert Ok(result) =
        typesafe.system_one(
          client,
          typesafe.system_one_request(ticket, [
            #(
              "duplicate",
              question.Noul(
                instructions: String(
                  "Is the customer reporting a duplicate charge?",
                ),
                if_true: Object([
                  #("meaning", String("the same amount charged more than once")),
                  #("examples", Array([String("billed twice")])),
                ]),
                if_false: Null,
              ),
            ),
            #(
              "tone",
              question.Choice(String("Tone?"), [
                #(
                  "calm",
                  Object([
                    #("summary", String("measured")),
                    #("examples", Array([String("please look into this")])),
                  ]),
                ),
                #("upset", Null),
              ]),
            ),
          ]),
        )
      show("rich descriptions", result.answers)
      let assert Ok(NoulAnswer(noul)) = dict.get(result.answers, "duplicate")
      assert noul >=. 0.0
      let assert Ok(ChoiceAnswer(probabilities:, ..)) =
        dict.get(result.answers, "tone")
      assert sorted_keys(probabilities) == ["calm", "upset"]
    }),
    #("rejects a bad API key with a 401", fn() {
      let bad =
        typesafe.new("not-a-real-key")
        |> typesafe.with_retry(
          retry.RetryPolicy(..retry.default_policy(), max_retries: 0),
        )
      let result = typesafe.list_models(bad)
      show("bad key", result)
      let assert Error(ApiError(status: 401, ..)) = result
      Nil
    }),
    #("rejects an unknown model with a readable 400", fn() {
      let result =
        typesafe.system_one(
          no_retries,
          SystemOneRequest(
            state: String("hello"),
            questions: [#("q", question.noul(String("Is this a greeting?")))],
            model: Some("no-such-model"),
            assets: [],
          ),
        )
      show("unknown model", result)
      let assert Error(ApiError(status: 400, message:, request_id:, ..)) =
        result
      assert message == "400 Unknown model: no-such-model"
      let assert Some(request_id) = request_id
      assert string.starts_with(request_id, "req_")
    }),
    #("surfaces server-side validation errors readably", fn() {
      // Content allows criteria the API rejects, so a 422 shows how one reads.
      let result =
        typesafe.system_one(
          no_retries,
          typesafe.system_one_request(String("x"), [
            #(
              "q",
              question.Score(String("?"), [content.Int(123), String("ok")]),
            ),
          ]),
        )
      show("422", result)
      let assert Error(ApiError(status: 422, message:, ..)) = result
      assert string.starts_with(message, "422 questions.q.score.criteria.0")
    }),
    #("catches shapes the API would reject before sending", fn() {
      let assert Error(InvalidRequest(_)) =
        typesafe.system_one(
          client,
          typesafe.system_one_request(String("x"), []),
        )
      let assert Error(InvalidRequest(_)) =
        typesafe.system_one(
          client,
          typesafe.system_one_request(String("x"), [
            #("q", question.Score(String("?"), [])),
          ]),
        )
      Nil
    }),
  ]
}

/// A 512x512 solid red PNG.
const red =
  "iVBORw0KGgoAAAANSUhEUgAAAgAAAAIAAQMAAADOtka5AAAABlBMVEX/AAAAAABBoxIDAAAANklEQVR42u3BAQEAAACCIP+vbkhAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB8G4IAAAFjdVCkAAAAAElFTkSuQmCC"

/// A 512x512 solid blue PNG.
const blue =
  "iVBORw0KGgoAAAANSUhEUgAAAgAAAAIAAQMAAADOtka5AAAABlBMVEUAAP8AAAB7Yr8+AAAANklEQVR42u3BAQEAAACCIP+vbkhAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB8G4IAAAFjdVCkAAAAAElFTkSuQmCC"

/// A 512x512 white PNG with a red square from 128 to 384 pixels on each axis.
const red_square_on_white =
  "iVBORw0KGgoAAAANSUhEUgAAAgAAAAIAAQMAAADOtka5AAAABlBMVEX/////AADrWueTAAAAZ0lEQVR42u3MQQ0AAAgEoOtfWiM4N/1BABIAAAAAAAAAgGM1EAgEAoFAIBAIBAKBQCAQCAQCgUAgEAgEAoFAIBAIBAKBQCAQCAQCgUAgEAgEAoFAIBAIBAKBQCD4DgAAAAAAAAAAlhrvN+HSAmCw9gAAAABJRU5ErkJggg=="

fn image_cases(client: Client) -> List(#(String, fn() -> Nil)) {
  let client =
    typesafe.with_header(client, "TypeSafe-Danger-Zone-Images", "true")
  let ask = fn(request) {
    let assert Ok(result) = typesafe.system_one(client, request)
    result.answers
  }

  [
    #("answers about an image in state", fn() {
      let answers =
        ask(
          typesafe.system_one_request(
            Array([String("Here is a photo:"), Asset(image(red))]),
            [
              #(
                "red",
                question.noul(String("Is the photo a solid red square?")),
              ),
            ],
          ),
        )
      show("inline image", answers)
      assert noul(answers, "red") >. 0.5
    }),
    #("answers about an image in text that is also in assets", fn() {
      let photo = image(red)
      let answers =
        ask(
          SystemOneRequest(
            state: Text([
              Literal("Compare <photo> with "),
              Embed(photo),
              Literal("."),
            ]),
            questions: [
              #("same", question.noul(String("Are both photos the same?"))),
            ],
            model: None,
            assets: [#("<photo>", photo)],
          ),
        )
      show("embedded image also in assets", answers)
      assert noul(answers, "same") >. 0.5
    }),
    #("answers about an image in question instructions", fn() {
      let answers =
        ask(
          typesafe.system_one_request(
            String("Look at the image in the question."),
            [
              #(
                "red",
                question.noul(
                  Array([
                    String("Is this image a solid red square?"),
                    Asset(image(red)),
                  ]),
                ),
              ),
            ],
          ),
        )
      show("image in question", answers)
      assert noul(answers, "red") >. 0.5
    }),
    #("compares the state image with images in question criteria", fn() {
      let answers =
        ask(
          typesafe.system_one_request(Asset(image(red)), [
            #(
              "color",
              question.Choice(
                String("Which sample has the same color as the state image?"),
                [#("red", Asset(image(red))), #("blue", Asset(image(blue)))],
              ),
            ),
            #(
              "similarity",
              question.Score(
                String("How similar is the state image to the examples?"),
                [Asset(image(blue)), Asset(image(red))],
              ),
            ),
          ]),
        )
      show("images in criteria", answers)
      let assert Ok(ChoiceAnswer(choice: "red", ..)) =
        dict.get(answers, "color")
      let assert Ok(ScoreAnswer(score:, ..)) = dict.get(answers, "similarity")
      assert score >. 0.5
    }),
    #("locates the red square with a box question", fn() {
      let answers =
        ask(
          SystemOneRequest(
            state: Asset(image(red_square_on_white)),
            questions: [
              #(
                "redSquare",
                question.Box(String("The red square in the center")),
              ),
            ],
            model: Some("jev-preview"),
            assets: [],
          ),
        )
      show("box", answers)
      let assert Ok(BoxAnswer(
        box: BoxCoordinates(top:, bottom:, left:, right:),
        confidence:,
      )) = dict.get(answers, "redSquare")
      assert case confidence {
        Some(confidence) -> confidence >=. 0.0
        None -> True
      }
      assert list.all([top, bottom, left, right], fn(edge) {
        edge >=. 0.0 && edge <=. 1.0
      })
    }),
  ]
}

fn image(base64: String) -> Image {
  let assert Ok(image) = content.image_from_base64(base64)
  image
}

fn noul(answers: Dict(String, Answer), name: String) -> Float {
  let assert Ok(NoulAnswer(noul)) = dict.get(answers, name)
  noul
}

fn sorted_keys(probabilities: Dict(String, Float)) -> List(String) {
  list.sort(dict.keys(probabilities), string.compare)
}

/// Whether the probabilities sum to 1 within the API's rounding.
fn sums_to_one(probabilities: Dict(a, Float)) -> Bool {
  float.absolute_value(float.sum(dict.values(probabilities)) -. 1.0) <. 0.05
}

fn show(label: String, value: a) -> Nil {
  io.println("\n--- " <> label <> " ---\n" <> string.inspect(value))
}

/// Run each case in order, printing its outcome, and halt with a failing
/// status if any case failed.
@external(erlang, "live_ffi", "run")
fn run(cases: List(#(String, fn() -> Nil))) -> Nil

@external(erlang, "typesafe_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)
