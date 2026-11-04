-module(live_ffi).
-export([run/1]).

run(Cases) ->
    Failed = [Name || {Name, Fun} <- Cases, not passes(Name, Fun)],
    io:format("~n~b passed, ~b failed~n", [length(Cases) - length(Failed), length(Failed)]),
    [io:format("  failed: ~ts~n", [Name]) || Name <- Failed],
    erlang:halt(case Failed of [] -> 0; _ -> 1 end).

passes(Name, Fun) ->
    io:format("~n=== ~ts~n", [Name]),
    try Fun() of
        _ -> io:format("ok~n"), true
    catch
        Class:Reason -> io:format("FAILED ~p:~n~p~n", [Class, Reason]), false
    end.
