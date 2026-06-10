%% --------------------------------------------------------------------------------
%% File:    erlroute_router.erl
%% @author  Oleksii Semilietov <spylik@gmail.com>
%%
%% Cross-node publish dispatcher. Sits next to the main `erlroute' gen_server
%% and owns the data plane for inbound `{remote_pub, ...}' envelopes: every
%% cross-node publish from a peer lands here instead of in `erlroute''s
%% mailbox.
%%
%% Splitting the control plane (subscribe / unsubscribe / nodeup / monitors,
%% handled by `erlroute') from the data plane (high-volume remote_pub fan-out,
%% handled here) means a publish burst can deepen this process's mailbox
%% without delaying a `gen_server:call(erlroute, {subscribe, _})' — which used
%% to time out at the 5s default when `erlroute' was the single funnel.
%% --------------------------------------------------------------------------------

-module(erlroute_router).

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([
        start_link/0,
        stop/0, stop/1
    ]).

-include("erlroute.hrl").

-define(SERVER, ?MODULE).

-spec start_link() -> Result when
    Result      :: {ok, Pid} | ignore | {error, Error},
    Pid         :: pid(),
    Error       :: {already_started, Pid} | term().

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec stop() -> ok.

stop() ->
    stop(sync).

-spec stop(Type) -> ok when
    Type        :: 'sync' | 'async'.

stop(sync) ->
    gen_server:stop(?SERVER);
stop(async) ->
    gen_server:cast(?SERVER, stop).

-spec init([]) -> {ok, []}.

init([]) ->
    {ok, []}.

-spec handle_call(Message, From, State) -> Result when
    Message     :: term(),
    From        :: {pid(), Tag},
    Tag         :: term(),
    State       :: [],
    Result      :: {reply, ok, []}.

handle_call(Msg, _From, State) ->
    error_logger:warning_msg("erlroute_router undefined handle_call with message ~p\n", [Msg]),
    {reply, ok, State}.

-spec handle_cast(Message, State) -> Result when
    Message     :: stop | term(),
    State       :: [],
    Result      :: {noreply, []} | {stop, normal, []}.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(Msg, State) ->
    error_logger:warning_msg("erlroute_router undefined handle_cast with message ~p\n", [Msg]),
    {noreply, State}.

-spec handle_info(Message, State) -> Result when
    Message     :: {remote_pub, module(), proc(), pos_integer(), topic(), payload(), pub_type(), atom()}
                 | term(),
    State       :: [],
    Result      :: {noreply, []}.

%% Fan a forwarded publish out locally with the publisher's original PubType.
%% Runs off the main erlroute process so a remote_pub backlog can't starve
%% subscribe / unsubscribe calls. ETS tables (?SUBETS, cache tables) are
%% public, so dispatch needs no coordination with erlroute.
handle_info({remote_pub, Module, Process, Line, Topic, Payload, PubType, EtsName}, State) ->
    _ = erlroute:pub(Module, Process, Line, Topic, Payload, PubType, EtsName),
    {noreply, State};

handle_info(Msg, State) ->
    error_logger:warning_msg("erlroute_router undefined handle_info with message ~p\n", [Msg]),
    {noreply, State}.

-spec terminate(Reason, State) -> term() when
    Reason      :: 'normal' | 'shutdown' | {'shutdown', term()} | term(),
    State       :: term().

terminate(_Reason, _State) ->
    ok.

-spec code_change(OldVsn, State, Extra) -> Result when
    OldVsn      :: Vsn | {down, Vsn},
    Vsn         :: term(),
    State       :: term(),
    Extra       :: term(),
    Result      :: {ok, NewState},
    NewState    :: term().

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
