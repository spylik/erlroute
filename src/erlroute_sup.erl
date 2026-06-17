-module(erlroute_sup).

% supervisor is here
-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> Result when
    Result :: 'ignore' | {'error',_} | {'ok',pid()}.

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec init([]) -> Result when
    Result :: {ok, {SupFlags :: supervisor:sup_flags(), [ChildSpec :: supervisor:child_spec()]}}.

init([]) ->
    %% An erlroute crash is FATAL to the node, by design. erlroute owns all
    %% routing state in its own process-linked ETS tables (no heir, no
    %% persistence) and links the whole router pool, so an in-place restart
    %% cannot recover — it would come back empty (local subscribers don't
    %% re-subscribe) and leave peers holding stale {Node, RouterPid} routes to
    %% the dead process (which never self-heal, since the node stays up and
    %% emits no nodedown). intensity 0 makes a single abnormal exit escalate:
    %% sup -> application -> (permanent app in a release) -> node halt. The
    %% node is then restarted by the platform, and recovery is clean — local
    %% subscribers re-subscribe on their own init, peers see nodedown/nodeup
    %% and re-discover. `transient` keeps a normal erlroute:stop/1 clean (no
    %% restart-escalation on graceful shutdown).
    RestartStrategy = {
        one_for_one,                           % Supervisor restart strategy
        0,                                     % Max restarts: 0 -> any crash escalates (fatal)
        1                                      % Period
    },

    Erlroute = {
        erlroute,                              % ID
        {erlroute, start_link, []},            % Start
        transient,                             % restart only on abnormal exit; intensity 0 then escalates -> node down
        5000,                                  % Shutdown strategy
        worker,                                % Child can be supervisor or worker
        [erlroute]                             % Option lists the modules that this process depends on
    },

    Childrens = [Erlroute],
    {ok, {RestartStrategy, Childrens}}.
