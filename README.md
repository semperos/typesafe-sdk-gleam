# typesafe

An unofficial Gleam client for the [TypeSafe AI](https://typesafe.ai) API, for
the Erlang target. TypeSafe doesn't maintain or endorse this package.

This package isn't published to Hex. Add it as a Git dependency in your
`gleam.toml`, pinned to a commit:

```toml
[dependencies]
typesafe = { git = "https://github.com/semperos/typesafe-sdk-gleam", ref = "<commit-sha>" }
```

Then run `gleam deps download`. Run `gleam docs build` in a clone of this
repository to generate the API docs locally.

```gleam
import gleam/dict
import typesafe
import typesafe/content.{String}
import typesafe/question

pub fn main() {
  let assert Ok(client) = typesafe.from_env()
  let assert Ok(result) =
    typesafe.system_one(
      client,
      typesafe.system_one_request(String("I was charged twice. Please help."), [
        #("billing", question.noul(String("Is this about billing?"))),
      ]),
    )
  dict.get(result.answers, "billing")
}
```

The SDK logs through the Erlang logger. Retries, timeouts, and connection
errors log at `warning`, so they show at the Erlang default level. Call
`logging.configure()` and `logging.set_level(logging.Debug)` from
`typesafe/logging` to see request summaries and bodies.

## Development

```sh
gleam test  # Run the tests
```

The live API tests in `test/live.gleam` need an API key, so `gleam test`
doesn't run them. Run them with `gleam run -m live`:

```sh
TYPESAFE_API_KEY=... gleam run -m live
TYPESAFE_API_KEY=... TYPESAFE_LIVE_IMAGES=1 gleam run -m live  # Include the image tests
```

## Attribution

Translated using Claude models from the [typesafe-sdk-js](https://github.com/typesafe-ai/typesafe-sdk-js) which has the following copyright and license:

> MIT License
>
> Copyright (c) 2026 TypeSafe
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

> The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

`src/typesafe/logging.gleam`, `src/typesafe/internal/log.gleam`, and
`src/typesafe_logging_ffi.erl` are adapted from
[lpil/logging](https://github.com/lpil/logging) v1.5.0 (commit `5499800`),
copyright Louis Pilfold, licensed under the
Apache License 2.0, whose text is in `LICENSE-APACHE`. Changes:
the Erlang module is renamed so it can't clash with the original package,
`allows` is added, the log functions move to an internal module, and the
formatter handles `{Format, Args}` messages and non-list reports.

## License

MIT License

Copyright (c) 2026 Daniel Gregoire

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
