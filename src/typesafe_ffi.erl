-module(typesafe_ffi).
-export([get_env/1, sleep/1, md5_hex/1, random_hex/0, has_zstd/0, zstd_compress/1,
         parse_http_date_ms/1, system_time_ms/0, monotonic_ms/0, unique_id/0,
         runtime/0]).

get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

sleep(Ms) ->
    timer:sleep(Ms),
    nil.

md5_hex(Data) ->
    binary:encode_hex(crypto:hash(md5, Data), lowercase).

random_hex() ->
    binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).

has_zstd() ->
    case code:ensure_loaded(zstd) of
        {module, zstd} -> erlang:function_exported(zstd, compress, 1);
        _ -> false
    end.

zstd_compress(Data) ->
    iolist_to_binary(zstd:compress(Data)).

parse_http_date_ms(Text) ->
    try httpd_util:convert_request_date(binary_to_list(Text)) of
        bad_date -> {error, nil};
        DateTime ->
            Seconds = calendar:datetime_to_gregorian_seconds(DateTime)
                - calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
            {ok, Seconds * 1000}
    catch
        _:_ -> {error, nil}
    end.

system_time_ms() ->
    os:system_time(millisecond).

monotonic_ms() ->
    erlang:monotonic_time(millisecond).

unique_id() ->
    erlang:unique_integer([positive, monotonic]).

runtime() ->
    Otp = erlang:system_info(otp_release),
    Arch = erlang:system_info(system_architecture),
    unicode:characters_to_binary(["erlang/", Otp, " (", Arch, ")"]).

