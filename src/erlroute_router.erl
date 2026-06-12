%% --------------------------------------------------------------------------------
%% File:    erlroute_router.erl
%% @author  Oleksii Semilietov <spylik@gmail.com>
%%
%% One member of the cross-node publish dispatch pool. Plain receive loop — no
%% gen_server overhead. Owned by erlroute_router_sup; N of these run per node
%% (configurable, default 10).
%%
%% Each router owns the data plane for the topics that hash to its index, so a
%% publish burst on one topic-set can't back up the dispatch of unrelated
%% topics — and never touches the main erlroute gen_server's mailbox, which
%% stays free for subscribe / unsubscribe control traffic.
%%
%% Addressed cross-node by raw pid: the subscriber node hashes each topic to a
%% router index, resolves that index to a pid, and hands the pid to publisher
%% nodes so they send straight here. On restart the registered name re-binds
%% and we announce our new pid to erlroute, which rebinds remote routes.
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
    _ = announce(Index),
    loop().

%% Tell the local erlroute (if up) our current pid for this index so it can
%% rebind cross-node routes after a restart. At boot erlroute may not be up
%% yet — it pulls the pool directly in its own init, so a missed announce
%% here is harmless.
-spec announce(Index :: pos_integer()) -> ok | {router_up, pos_integer(), pid()}.

announce(Index) ->
    case whereis(erlroute) of
        undefined -> ok;
        Erlroute  -> Erlroute ! {router_up, Index, self()}
    end.

-spec loop() -> no_return().

loop() ->
    receive
        {remote_pub, Module, Process, Line, Topic, Payload, PubType, EtsName} ->
            %% Crash-proof: a throwing pub must not take the router down, or
            %% its restart would orphan every remote route pointing at our pid
            %% until the rebind lands.
            _ = try
                erlroute:pub(Module, Process, Line, Topic, Payload, PubType, EtsName)
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
