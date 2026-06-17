%% --------------------------------------------------------------------------------
%% File:    erlroute_router.erl
%% @author  Oleksii Semilietov <spylik@gmail.com>
%%
%% One member of the cross-node publish dispatch pool. Plain receive loop,
%% spawn_linked directly from erlroute (no supervisor, no registered name).
%% Addressed cross-node by raw pid: erlroute assigns each topic to a router
%% (round-robin, sticky) and propagates that pid (see erlroute:assign_router/1).
%% --------------------------------------------------------------------------------

-module(erlroute_router).

-define(NOTEST, true).
-ifdef(TEST).
    -compile(export_all).
    -compile(nowarn_export_all).
-endif.

-export([start_link/0, init/1]).

-include("erlroute.hrl").

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    proc_lib:start_link(?MODULE, init, [self()]).

-spec init(Parent :: pid()) -> no_return().

init(Parent) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    loop().

-spec loop() -> no_return().

loop() ->
    receive
        {remote_pub, async, Topic, Payload} ->
            spawn(fun() ->
                _ = try erlroute:pub_local(Topic, Payload)
                    catch Class:Reason:St ->
                        error_logger:error_msg(
                            "erlroute_router dispatch failed for topic ~p: ~p:~p~n~p~n",
                            [Topic, Class, Reason, St])
                    end
            end),
            loop();
        {remote_pub, sync, Topic, Payload} ->
            _ = try erlroute:pub_local(Topic, Payload)
                catch Class:Reason:St ->
                    error_logger:error_msg(
                        "erlroute_router dispatch failed for topic ~p: ~p:~p~n~p~n",
                        [Topic, Class, Reason, St])
                end,
            loop();
        Msg ->
            error_logger:warning_msg("erlroute_router received unexpected message ~p~n", [Msg]),
            loop()
    end.
