%% --------------------------------------------------------------------------------
%% File:    erlroute_router.erl
%% @author  Oleksii Semilietov <spylik@gmail.com>
%%
%% One member of the cross-node publish dispatch pool. Plain receive loop,
%% spawn_linked directly from erlroute (no supervisor); addressed cross-node by
%% its registered name erlroute_router_<Index> (see erlroute:router_index/1,
%% erlroute:router_name/1).
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
    loop().

-spec loop() -> no_return().

loop() ->
    receive
        {remote_pub, Module, Process, Line, Topic, Payload, _PubType, EtsName} ->
            %% local-only: deliver to this node's subscribers, never re-forward
            _ = try
                erlroute:pub_local(Module, Process, Line, Topic, Payload, EtsName)
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
