%% --------------------------------------------------------------------------------
%% File:    erlroute_router_sup.erl
%% @author  Oleksii Semilietov <spylik@gmail.com>
%%
%% Supervisor for the erlroute_router pool. Starts N routers (configurable via
%% `{erlroute, router_pool_size}', default 10), each registered as
%% erlroute_router_<Index>. one_for_one so a single router crash restarts only
%% that router; the restarted process announces its new pid to erlroute, which
%% rebinds affected cross-node routes.
%% --------------------------------------------------------------------------------

-module(erlroute_router_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-include("erlroute.hrl").

-define(SERVER, ?MODULE).

-spec start_link() -> 'ignore' | {'error', _} | {'ok', pid()}.

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.

init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 10,
        period    => 10
    },
    N = erlroute:router_pool_size(),
    Children = [
        #{
            id       => Index,
            start    => {erlroute_router, start_link, [Index]},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [erlroute_router]
        }
        || Index <- lists:seq(1, N)
    ],
    {ok, {SupFlags, Children}}.
