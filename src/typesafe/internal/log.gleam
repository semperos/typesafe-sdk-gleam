//// The SDK's own log calls, kept out of the public API.
////
//// Adapted from lpil/logging v1.5.0 (Apache-2.0). See the README.

import typesafe/logging.{type LogLevel}

type DoNotLeak

pub fn log(level: LogLevel, message: String) -> Nil {
  erlang_log(level, message)
  Nil
}

/// Whether the logger would output a message at `level` from this package,
/// to skip building messages nobody will see.
pub fn allows(level: LogLevel) -> Bool {
  erlang_allow(level, Typesafe)
}

@external(erlang, "logger", "log")
fn erlang_log(level: LogLevel, message: String) -> DoNotLeak

@external(erlang, "logger", "allow")
fn erlang_allow(level: LogLevel, module: ModuleName) -> Bool

type ModuleName {
  Typesafe
}
