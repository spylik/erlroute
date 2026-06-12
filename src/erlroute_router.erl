%% --------------------------------------------------------------------------------
%% File:    erlroute_router.erl
%% @author  Oleksii Semilietov <spylik@gmail.com>
%%
%% One member of the cross-node publish dispatch pool. Plain receive loop owned
%% by erlroute_router_sup; addressed cross-node by raw pid (see erlroute:assign_router/1).
%% --------------------------------------------------------------------------------

-module(erlroute_router).

-define(NOTEST, true).
-ifdef(TEST).
    -compile(export_all).
    -compile(nowarn_export_all).
-endif.

-export([start_link/1, init/2]).

-include("erlroute.hrl").

-spec start_link(Index :: pos_integer()) -> {ok, pid()} | {error, term()}.

start_link(Index) ->
    proc_lib:start_link(?MODULE, init, [self(), Index]).

-spec init(Parent :: pid(), Index :: pos_integer()) -> no_return().

init(Parent, Index) ->
    true = register(erlroute:router_name(Index), self()),
    proc_lib:init_ack(Parent, {ok, self()}),
    %% We only ever dispatch inbound remote publishes — deliver to local
    %% subscribers, never re-forward across nodes (the origin already reached
    %% every node). erlroute:send/9 reads this flag; see its on_other_node
    %% clauses. Forcing `sync' below keeps the whole fan-out in this process so
    %% the flag is in scope throughout.
    put('$erlroute_local_dispatch', true),
    _ = announce(Index),
    loop().

% erlroute pulls the pool in its own init, so a missed announce at boot (erlroute
% not up yet) is harmless; on a restart it lets erlroute rebind remote routes.
-spec announce(Index :: pos_integer()) -> ok | {router_up, pos_integer(), pid()}.

announce(Index) ->
    case whereis(erlroute) of
        undefined -> ok;
        Erlroute  -> Erlroute ! {router_up, Index, self()}
    end.

-spec loop() -> no_return().

loop() ->
    receive
        {remote_pub, Module, Process, Line, Topic, Payload, _PubType, EtsName} ->
            _ = try
                erlroute:pub(Module, Process, Line, Topic, Payload, sync, EtsName)
            catch
                Class:Reason:St ->
                    error_logger:error_msg(
                        "erlroute_router dispatch failed for topic ~p: ~p:~p~n~p~n",
                        [Topic, Class, Reason, St]
                    )
            end,
            loop();
        Msg ->
            error_logger:warning_msg("erlroute_router received unexpected message ~p~n", [Msg]),
            loop()
    end.
