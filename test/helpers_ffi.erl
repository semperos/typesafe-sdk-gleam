-module(helpers_ffi).
-export([new_ref/0, append/2, values/1, zstd_decompress/1, split/2, split_once/2,
         put_env/2, unset_env/1, capture_logs/2, log/2, remove_default_handler/0]).

new_ref() -> make_ref().

append(Ref, Value) ->
    put(Ref, values(Ref) ++ [Value]),
    nil.

values(Ref) ->
    case get(Ref) of
        undefined -> [];
        Values -> Values
    end.

zstd_decompress(Data) -> iolist_to_binary(zstd:decompress(Data)).

split(Data, Separator) -> binary:split(Data, Separator, [global]).

split_once(Data, Separator) ->
    case binary:split(Data, Separator) of
        [Before, After] -> {ok, {Before, After}};
        _ -> {error, nil}
    end.

put_env(Name, Value) ->
    os:putenv(binary_to_list(Name), binary_to_list(Value)),
    nil.

unset_env(Name) ->
    os:unsetenv(binary_to_list(Name)),
    nil.

capture_logs(Level, Run) ->
    Ref = make_ref(),
    #{level := Previous} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, Level),
    ok = logger:add_handler(helpers_capture, ?MODULE, #{config => Ref}),
    try
        Result = Run(),
        {Result, values(Ref)}
    after
        logger:remove_handler(helpers_capture),
        logger:set_primary_config(level, Previous)
    end.

log(#{level := Level, msg := {string, Message}}, #{config := Ref}) ->
    append(Ref, {Level, unicode:characters_to_binary(Message)}).

remove_default_handler() ->
    logger:remove_handler(default),
    nil.
