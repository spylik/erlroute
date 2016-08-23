-module(erlroute_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).


-spec start(Type, Args) -> Result when
    Type :: application:start_type(),
    Args :: term(),
    Result :: {'ok', pid()} | {'ok', pid(), State :: term()} | {'error', Reason :: term()}.

start(_Type, _Args) ->
    erlroute_sup:start_link().

-spec stop(State) -> Result when
    State :: term(),
    Result :: ok.

stop(_State) ->
    ok.
