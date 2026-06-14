%% --------------------------------------------------------------------------------
%% File:    erlroute.erl
%% @author  Oleksii Semilietov <spylik@gmail.com>
%%
%% --------------------------------------------------------------------------------

-module(erlroute).
-define(NOTEST, true).
-ifdef(TEST).
    -compile(export_all).
    -compile(nowarn_export_all).
-endif.

-define(SUBETS, '$erlroute_subscribers').
-define(ROUTERETS, '$erlroute_routers').

-define(DEFAULT_TIMEOUT_FOR_RPC, 1000).
-define(SERVER, ?MODULE).

-include("erlroute.hrl").

-behaviour(gen_server).

% export standart gen_server api
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

% export start/stop api
-export([
        start_link/0,
        stop/0, stop/1
    ]).

% export our custom api
-export([
        pub/1,  % translate to pub/7
        pub/2,  % translate to pub/7
        pub/5,  % translate to pub/7
        pub/7,
        pub_local/6,  % local-only dispatch entry point for erlroute_router
        full_async_pub/5,
        full_sync_pub/5,
        sub/2,
        sub/1,
        unsub/2,
        unsub/1,
        cache_table/1, % export support function for parse_transform
        post_hitcache_routine/10,
        gen_static_fun_dest/2,
        erlroute_cache_etses/0
    ]).

% ----------------------------- gen_server part --------------------------------

% @doc start api
-spec start_link() -> Result when
    Result      :: {ok, Pid} | ignore | {error, Error},
    Pid         :: pid(),
    Error       :: {already_started,Pid} | term().

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

% @doc simplified stop api. Defaul is sync call gen_server:stop
-spec stop() -> ok.

stop() ->
    stop(sync).

% @doc async/sync stop
-spec stop(Type) -> ok when
    Type        :: 'sync' | 'async'.

stop(sync) ->
    gen_server:stop(?SERVER);
stop(async) ->
    gen_server:cast(?SERVER, stop).

% @doc gen_server init. We going to create ETS tables for dynamic routing rules in init section
-spec init([]) -> {ok, erlroute_state()}.

init([]) ->
    %% Trap exits so a router death arrives as a message (we stop on it) and so
    %% terminate/2 runs on every controlled stop to tear the pool down cleanly.
    process_flag(trap_exit, true),
    _ = ets:new('$erlroute_topics', [
            bag,
            public, % public for support full sync pub
            {read_concurrency, true}, % todo: test does it affect performance for writes?
            {keypos, #topics.topic},
            named_table
        ]),
    _ = ets:new(?SUBETS, [
            bag,
            public, % public for support full sync pub,
            {read_concurrency, true}, % todo: test doesrt affect performance for writes?
            {keypos, #subscriber.topic},
            named_table
        ]),
    _ = ets:new(?ROUTERETS, [set, public, named_table, {read_concurrency, true}]),
    _ = ets:new(?REMOTETS, [set, public, named_table, {keypos, #remote_sub.key}]),
    Routers = start_routers(router_pool_size()),
    true = ets:insert(?ROUTERETS, [{'$routers', list_to_tuple(Routers)}, {'$next', 0}]),
    _ = net_kernel:monitor_nodes(true),
    _ = ping_nodes(nodes()),
    {ok, #erlroute_state{}}.

% Spawn the linked, anonymous router pool.
-spec start_routers(N :: pos_integer()) -> [pid()].

start_routers(N) ->
    [begin {ok, Pid} = erlroute_router:start_link(), Pid end || _ <- lists:seq(1, N)].

%--------------handle_call-----------------

 %@doc callbacks for gen_server handle_call.
-spec handle_call(Message, From, State) -> Result when
    Message     :: SubMsg | UnsubMsg,
    SubMsg      :: {'subscribe', flow_source(), flow_dest()},
    UnsubMsg    :: {'unsubscribe', flow_source(), flow_dest()},
    From        :: {pid(), Tag},
    Tag         :: term(),
    State       :: erlroute_state(),
    Result      :: {reply, term(), erlroute_state()}.

handle_call({subscribe, #flow_source{module = Module, topic = Topic} = FlowSource, FlowDest}, _From, #erlroute_state{erlroute_nodes = ErlrouteNodes, monitors = Monitors} = State) ->
    Before = delivery_descriptor(Topic, Module),
    ProbablyMoreMonitors = may_establish_monitor(FlowDest, Monitors),
    Result = subscribe(FlowSource, FlowDest),
    _ = propagate_local_change(Topic, Module, Before, ErlrouteNodes),
    {reply, Result, State#erlroute_state{monitors = ProbablyMoreMonitors}};

handle_call({unsubscribe, #flow_source{module = Module, topic = Topic} = FlowSource, FlowDest}, _From, #erlroute_state{erlroute_nodes = ErlRouteNodes, monitors = Monitors} = State) ->
    Before = delivery_descriptor(Topic, Module),
    delete_local_subscriber(FlowSource, FlowDest),
    _ = propagate_local_change(Topic, Module, Before, ErlRouteNodes),
    {reply, ok, State#erlroute_state{monitors = may_release_monitor(FlowDest, Monitors)}};

handle_call({regtable, EtsName}, _From, State) ->
    {reply, route_table_must_present(EtsName), State};

% @doc unspec case for unknown messages
handle_call(Msg, _From, State) ->
    error_logger:warning_msg("we are in undefined handle_call with message ~p\n",[Msg]),
    {reply, ok, State}.

%-----------end of handle_call-------------


%--------------handle_cast-----------------

-spec handle_cast(Message, State) -> Result when
    Message     :: stop,
    State       :: erlroute_state(),
    Result      :: {noreply, State} | {stop, normal, State}.

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle_cast with message ~p\n",[Msg]),
    {noreply, State}.

%-----------end of handle_cast-------------

%--------------handle_info-----------------

% @doc callbacks for gen_server handle_info.
-spec handle_info(Message, State) -> Result when
    Message     :: {nodeup, node()}
                 | {nodedown, node()}
                 | {erlroute_ping, node()}
                 | {erlroute_sync, node(), [{flow_source(), delivery_descriptor()}]}
                 | {set_remote_route, flow_source(), delivery_descriptor(), node()}
                 | {remove_remote_route, flow_source(), node()}
                 | {'DOWN', reference(), process, pid(), term()}
                 | {'EXIT', pid(), term()},
    State       :: erlroute_state(),
    Result      :: {noreply, erlroute_state()}.

handle_info({nodeup, Node}, State) ->
    _ = case Node =/= node() of
        true  -> ping_node(Node);
        false -> ok
    end,
    {noreply, State};

handle_info({nodedown, Node}, #erlroute_state{erlroute_nodes = Nodes} = State) ->
    _ = unsubscribe_node(Node),
    {noreply, State#erlroute_state{erlroute_nodes = Nodes -- [Node]}};

handle_info({erlroute_ping, Node}, #erlroute_state{erlroute_nodes = Nodes} = State) ->
    case Node =:= node() orelse lists:member(Node, Nodes) of
        true ->
            {noreply, State};
        false ->
            _ = announce_to(Node),
            {noreply, State#erlroute_state{erlroute_nodes = [Node | Nodes]}}
    end;

handle_info({erlroute_sync, Node, _Descriptors}, State) when Node =:= node() ->
    {noreply, State};
handle_info({erlroute_sync, Node, Descriptors}, #erlroute_state{erlroute_nodes = Nodes} = State) ->
    _ = apply_remote_descriptors(Node, Descriptors),
    case lists:member(Node, Nodes) of
        true ->
            {noreply, State};
        false ->
            _ = announce_to(Node),
            {noreply, State#erlroute_state{erlroute_nodes = [Node | Nodes]}}
    end;

handle_info({set_remote_route, FlowSource, Descriptor, Node}, State) ->
    _ = upsert_remote_route(FlowSource, Node, Descriptor),
    {noreply, State};

handle_info({remove_remote_route, FlowSource, Node}, State) ->
    _ = remove_remote_routes(FlowSource, Node),
    {noreply, State};

handle_info({'DOWN', _Ref, process, Pid, _Reason}, #erlroute_state{monitors = Monitors, erlroute_nodes = ErlRouteNodes} = State) ->
    _ = unsubscribe_local_pid(Pid, ErlRouteNodes),
    {noreply, State#erlroute_state{monitors = maps:remove(Pid, Monitors)}};

% A pool router died — which is not supposed to happen. Take erlroute down with
% it; erlroute_sup restarts the whole pool together.
handle_info({'EXIT', Pid, Reason}, State) ->
    case lists:member(Pid, router_pids()) of
        true  -> {stop, {router_died, Pid, Reason}, State};
        false -> {noreply, State}
    end;

% @doc case for unknown messages
handle_info(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle_info with message ~p\n",[Msg]),
    {noreply, State}.

%-----------end of handle_info-------------

-spec terminate(Reason, State) -> ok when
    Reason      :: 'normal' | 'shutdown' | {'shutdown',term()} | term(),
    State       :: erlroute_state().

terminate(_Reason, _State) ->
    _ = stop_routers(router_pids()),
    ok.

% Current router pids (the pool tuple as a list); [] if the pool table is gone.
-spec router_pids() -> [pid()].

router_pids() ->
    try ets:lookup_element(?ROUTERETS, '$routers', 2) of
        Routers -> tuple_to_list(Routers)
    catch
        _:_ -> []
    end.

-spec stop_routers(Routers :: [pid()]) -> ok.

stop_routers(Routers) ->
    lists:foreach(fun(Pid) ->
        unlink(Pid),
        MRef = erlang:monitor(process, Pid),
        exit(Pid, kill),
        receive {'DOWN', MRef, process, Pid, _} -> ok after 1000 -> ok end
    end, Routers).

-spec code_change(OldVsn, State, Extra) -> Result when
    OldVsn      :: Vsn | {down, Vsn},
    Vsn         :: term(),
    State       :: term(),
    Extra       :: term(),
    Result      :: {ok, NewState},
    NewState    :: term().

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% ============================= end of gen_server part =========================
% ----------------------------------- pub part ---------------------------------

% @doc Publish message API. Default is hybrid behaviour:
% - check if route table existing (cache per module)
% - for cached routes it send message sync
% - at the end it cast to erlroute and erlroute try to match not yet cached routes via async way
%
% Also aviable 'erlroute:full_async_pub/5' and 'erlroute:full_sync_pub/5' with same parameters.
%
% For publish avialiable following parse_transform and macros shourtcuts:
%
% pub(Payload) ----> generating topic and transforming to
% pub(?MODULE, self(), ?LINE, <<"?MODULE.?LINE">>, Payload, hybrid, '$erlroute_?MODULE')
%
% pub(Topic, Payload) ----> transforming to
% pub(?MODULE, self(), ?LINE, Topic, Payload, hybrid, '$erlroute_?MODULE')
%
% To use parse transform +{parse_transform, erlroute_transform} must be added as compile options.
%
% Return: return depends on what kind of behaviour has choosen.
% - for hybrid it return list of process where erlroute send message matched from cache. It doesn't include post-matching.
% - for async it always return empty list.
% - for sync it return full list of destination where erlroute actually route payload.


% shortcut (should use parse transform better than pub/1)
-spec pub(Payload) -> Result when
    Payload ::  payload(),
    Result  ::  pub_result().

pub(Payload) ->
    Module = ?MODULE,
    Line = ?LINE,
    Topic = list_to_binary(lists:concat([Module,",",Line])),
    error_logger:warning_msg("Attempt to use pub/1 without parse_transform. ?MODULE, ?LINE and Topic will be wrong."),
    pub(Module, self(), Line, Topic, Payload, 'hybrid', cache_table(Module)).

% shortcut (should use parse transform better than pub/2)
-spec pub(Topic, Payload) -> Result when
    Topic   ::  topic(),
    Payload ::  payload(),
    Result  ::  pub_result().

pub(Topic, Payload) ->
    Module = ?MODULE,
    Line = ?LINE,
    error_logger:warning_msg("Attempt to use pub/2 without parse_transform. ?MODULE and ?LINE will be wrong."),
    pub(Module, self(), Line, Topic, Payload, 'hybrid', cache_table(Module)).

% hybrid
-spec pub(Module, Process, Line, Topic, Payload) -> Result when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  topic(),
    Payload ::  payload(),
    Result  ::  pub_result().

pub(Module, Process, Line, Topic, Payload) ->
    error_logger:warning_msg("Attempt to use pub/5 without parse_transform."),
    pub(Module, Process, Line, Topic, Payload, 'hybrid', cache_table(Module)).

% full_async
-spec full_async_pub(Module, Process, Line, Topic, Payload) -> Result when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  topic(),
    Payload ::  payload(),
    Result  ::  []. % in async we always return [] cuz we don't know yet subscribers

full_async_pub(Module, Process, Line, Topic, Payload) ->
    pub(Module, Process, Line, Topic, Payload, async, cache_table(Module)).

% full_sync
-spec full_sync_pub(Module, Process, Line, Topic, Payload) -> Result when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  topic(),
    Payload ::  payload(),
    Result  ::  pub_result().

full_sync_pub(Module, Process, Line, Topic, Payload) ->
    pub(Module, Process, Line, Topic, Payload, sync, cache_table(Module)).

% @doc full parameter pub
-spec pub(Module, Process, Line, Topic, Payload, PubType, EtsName) -> Result when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  topic(),
    Payload ::  payload(),
    PubType ::  pub_type(),
    EtsName ::  atom(),
    Result  ::  pub_result().

pub(Module, Process, Line, Topic, Payload, hybrid = PubType, EtsName) ->
    WhoGetWhileSync = load_routing_and_send(
        ets:whereis(EtsName),
        EtsName,
        Module,
        Process,
        Line,
        PubType,
        Topic,
        Payload,
        [],
        all
    ),
    PostRef = gen_id(),
    spawn(?MODULE, post_hitcache_routine, [Module, Process, Line, PubType, Topic, Payload, EtsName, WhoGetWhileSync, PostRef, all]),
    WhoGetWhileSync;

pub(Module, Process, Line, Topic, Payload, async, EtsName) ->
    spawn(?MODULE, pub, [Module, Process, Line, Topic, Payload, sync, EtsName]),
    [];

pub(Module, Process, Line, Topic, Payload, sync, EtsName) ->
    do_sync_pub(Module, Process, Line, Topic, Payload, EtsName, all).

% @doc Local-only sync dispatch: deliver to this node's subscribers but never
% re-forward to cross-node routes. Used by erlroute_router when fanning out an
% inbound remote publish — the originating node already reached every node.
-spec pub_local(Module, Process, Line, Topic, Payload, EtsName) -> Result when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  topic(),
    Payload ::  payload(),
    EtsName ::  atom(),
    Result  ::  pub_result().

pub_local(Module, Process, Line, Topic, Payload, EtsName) ->
    do_sync_pub(Module, Process, Line, Topic, Payload, EtsName, local).

% Sync publish: cache-hit dispatch (load_routing_and_send) then lazy match +
% cache populate (post_hitcache_routine). Scope = all routes to local AND
% cross-node destinations; local skips the cross-node ones (a router fanning out
% an inbound remote_pub).
-spec do_sync_pub(Module, Process, Line, Topic, Payload, EtsName, Scope) -> Result when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  topic(),
    Payload ::  payload(),
    EtsName ::  atom(),
    Scope   ::  scope(),
    Result  ::  pub_result().

do_sync_pub(Module, Process, Line, Topic, Payload, EtsName, Scope) ->
    post_hitcache_routine(
        Module,
        Process,
        Line,
        sync,
        Topic,
        Payload,
        EtsName,
        load_routing_and_send(
            ets:whereis(EtsName),
            EtsName,
            Module,
            Process,
            Line,
            sync,
            Topic,
            Payload,
            [],
            Scope
        ),
        undefined,
        Scope
    ).

-spec load_routing_and_send(EtsTid, EtsName, Module, Process, Line, PubType, Topic, Payload, Acc, Scope) -> Result when
    EtsTid          :: undefined | ets:tid(),
    EtsName         :: atom(),
    Module          :: module(),
    Process         :: proc(),
    Line            :: pos_integer(),
    PubType         :: pub_type(),
    Topic           :: topic(),
    Payload         :: payload(),
    Acc             :: pub_result(),
    Scope           :: scope(),
    Result          :: pub_result().

load_routing_and_send(undefined, _EtsName, _Module, _Process, _Line, _PubType, _Topic, _Payload, Acc, _Scope) -> Acc;
load_routing_and_send(EtsTid, EtsName, Module, Process, Line, PubType, Topic, Payload, Acc, Scope) ->
    try ets:lookup(EtsTid, Topic) of
        [] when Topic =/= <<"#">> ->
            load_routing_and_send(EtsTid, EtsName, Module, Process, Line, PubType, <<"#">>, Payload, Acc, Scope);
        [] ->
            Acc;
        Routes when Topic =/= <<"#">> ->
            % send to wildcard-topic subscribers
            load_routing_and_send(EtsTid, EtsName, Module, Process, Line, PubType, <<"#">>, Payload, send(Routes, Payload, Module, Process, Line, PubType, Topic, EtsName, Acc, Scope), Scope);
        Routes ->
            send(Routes, Payload, Module, Process, Line, PubType, Topic, EtsName, Acc, Scope)
    catch
        _:_ ->
            Acc
    end.

-spec send(Routes, Payload, Module, Process, Line, PubType, Topic, EtsName, Acc, Scope) -> Result when
    Routes          :: [cached_route()],
    Payload         :: payload(),
    Module          :: module(),
    Process         :: proc(),
    Line            :: pos_integer(),
    PubType         :: pub_type(),
    Topic           :: topic(),
    EtsName         :: atom(),
    Acc             :: pub_result(),
    Scope           :: scope(),
    Result          :: pub_result().

% sending to standart process
send([#cached_route{dest_type = 'process', method = Method, dest = Dest}|T], Payload, Module, Process, Line, PubType, Topic, EtsName, Acc, Scope) ->
    case Method of
        info -> Dest ! Payload;
        cast -> gen_server:cast(Dest, Payload);
        call ->
            try
                gen_server:call(Dest, Payload)
            catch
                Error:Reason ->
		            error_logger:error_msg(
		                "failed to dispatch message ~p via gen_server:call to ~p for topic ~p. Failed with reason: ~p:~p.",
		                [Payload, Dest, Topic, Error, Reason]
		            )
			end

    end,
    send(T, Payload, Module, Process, Line, PubType, Topic, EtsName, [{Dest, Method} | Acc], Scope);

% apply process
send([#cached_route{dest_type = 'function', method = Method, dest = {Function, ShellIncludeTopic} = Dest}|T], Payload, Module, Process, Line, PubType, Topic, EtsName, Acc, Scope) ->
    try
        case Method of
            cast ->
                case {is_function(Function), ShellIncludeTopic} of
                    {true, true} ->
                        spawn(fun() -> erlang:apply(Function, [Topic, Payload]) end);
                    {true, false} ->
                        spawn(fun() -> erlang:apply(Function, [Payload]) end);
                    {false, true} ->
                        {M, F, A} = Function,
                        spawn(M, F, [Topic, Payload | A]);
                    {false, false} ->
                        {M, F, A} = Function,
                        spawn(M, F, [Payload | A])
                end;
            call ->
                case {is_function(Function), ShellIncludeTopic} of
                    {true, true} ->
                        erlang:apply(Function, [Topic, Payload]);
                    {true, false} ->
                        erlang:apply(Function, [Payload]);
                    {false, true} ->
                        {M, F, A} = Function,
                        apply(M, F, [Topic, Payload | A]);
                    {false, false} ->
                        {M, F, A} = Function,
                        apply(M, F, [Payload | A])
                end;
            {Node, cast} when is_atom(Node) ->
                case ShellIncludeTopic of
                    true ->
                        erpc:cast(Node, fun() -> erlang:apply(Function, [Topic, Payload]) end);
                    false ->
                        erpc:cast(Node, fun() -> erlang:apply(Function, [Payload]) end)
                end;
            {Node, call} when is_atom(Node) ->
                case {is_function(Function), ShellIncludeTopic} of
                    {true, true} ->
                        erpc:call(Node, fun() -> erlang:apply(Function, [Topic, Payload]) end, ?DEFAULT_TIMEOUT_FOR_RPC);
                    {true, false} ->
                        erpc:call(Node, fun() -> erlang:apply(Function, [Payload]) end, ?DEFAULT_TIMEOUT_FOR_RPC);
                    {false, true} ->
                        {M, F, A} = Function,
                        erpc:call(Node, M, F, [Topic, Payload | A], ?DEFAULT_TIMEOUT_FOR_RPC);
                    {false, false} ->
                        {M, F, A} = Function,
                        erpc:call(Node, M, F, [Topic, Payload | A], ?DEFAULT_TIMEOUT_FOR_RPC)
                end
        end
    catch
        Error:Reason ->
            error_logger:error_msg(
                "failed to dispatch message ~p via function ~p for topic ~p. Failed with reason: ~p:~p.",
                [Payload, Function, Topic, Error, Reason]
            )
    end,
    send(T, Payload, Module, Process, Line, PubType, Topic, EtsName, [{Dest, Method} | Acc], Scope);

% sending to poolboy pool
send([#cached_route{dest_type = 'poolboy', method = Method, dest = PoolName}|T], Payload, Module, Process, Line, PubType, Topic, EtsName, Acc, Scope) ->
    _ = try
        Worker = poolboy:checkout(PoolName),
        case Method of
            info -> Worker ! Payload;
            cast -> gen_server:cast(Worker, Payload);
            call -> gen_server:call(Worker, Payload)
        end,
        poolboy:checkin(PoolName, Worker)
    catch
        X:Y -> error_logger:error_msg("Looks like poolboy pool ~p not found, got error ~p with reason ~p",[PoolName,X,Y]), Acc
    end,
    send(T, Payload, Module, Process, Line, PubType, Topic, EtsName, [{PoolName, Method} | Acc], Scope);

% Cross-node routes. With Scope =:= local (a router fanning out an inbound
% remote_pub) the actual send is skipped: the originating node already reached
% every node, so re-forwarding would just duplicate / loop. The route is still
% marked in Acc so post_hitcache won't resend it.
send([#cached_route{dest_type = 'process_on_other_node', method = info, dest = {_Node, Proc} = Dest}|T], Payload, Module, Process, Line, PubType, Topic, EtsName, Acc, Scope) when is_pid(Proc) ->
    _ = Scope =:= local orelse erlang:send(Proc, Payload),
    send(T, Payload, Module, Process, Line, PubType, Topic, EtsName, [{Dest, info} | Acc], Scope);

send([#cached_route{dest_type = 'process_on_other_node', method = info, dest = {Node, Proc} = Dest}|T], Payload, Module, Process, Line, PubType, Topic, EtsName, Acc, Scope) when is_atom(Proc) ->
    _ = Scope =:= local orelse erlang:send({Proc, Node}, Payload),
    send(T, Payload, Module, Process, Line, PubType, Topic, EtsName, [{Dest, info} | Acc], Scope);

send([#cached_route{dest_type = 'process_on_other_node', method = cast, dest = {_Node, Proc} = Dest}|T], Payload, Module, Process, Line, PubType, Topic, EtsName, Acc, Scope) when is_pid(Proc) ->
    _ = Scope =:= local orelse erlang:send(Proc, {'$gen_cast', Payload}),
    send(T, Payload, Module, Process, Line, PubType, Topic, EtsName, [{Dest, cast} | Acc], Scope);

send([#cached_route{dest_type = 'process_on_other_node', method = cast, dest = {Node, Proc} = Dest}|T], Payload, Module, Process, Line, PubType, Topic, EtsName, Acc, Scope) when is_atom(Proc) ->
    _ = Scope =:= local orelse erlang:send({Proc, Node}, {'$gen_cast', Payload}),
    send(T, Payload, Module, Process, Line, PubType, Topic, EtsName, [{Dest, cast} | Acc], Scope);

send([#cached_route{dest_type = 'erlroute_on_other_node', method = Method, dest = {_Node, RouterPid} = Dest}|T], Payload, Module, Process, Line, PubType, Topic, EtsName, Acc, Scope) ->
    _ = Scope =:= local orelse erlang:send(RouterPid, {remote_pub, Module, Process, Line, Topic, Payload, PubType, EtsName}),
    send(T, Payload, Module, Process, Line, PubType, Topic, EtsName, [{Dest, Method} | Acc], Scope);

% final clause for empty list
send([], _Payload, _Module, _Process, _Line, _PubType, _Topic, _EtsName, Acc, _Scope) -> Acc.

% ================================ end of pub part =============================
% ----------------------------------- sub part ---------------------------------

% @doc Subscribe API to the message flow.
% Erlroute suport pid, registered process name and the message pool like https://github.com/devinus/poolboy[Poolboy^] as destination.
% For the process subscribed by pid or registered name it just send message.
% For the pools for every new message it checkout one worker, then send message to that worker and then checkin.

-spec sub(Target) -> ok when
    Target  :: flow_source() | [{topic, topic()} | {module, module()}] | topic() | module().

% @doc subscribe current process to all messages from module Module
sub(Module) when is_atom(Module) -> sub(#flow_source{module = Module, topic = <<"#">>}, {process, self(), info});

% @doc subscribe current process to messages with topic Topic from any module
sub(Topic) when is_binary(Topic) -> sub(#flow_source{module = undefined, topic = Topic}, {process, self(), info});

% @doc subscribe current process to messages with full-defined FlowSource ([{module, Module}, {topic, Topic}])
sub(FlowSource) when is_list(FlowSource) -> sub(FlowSource, {process, self(), info}).

% @doc full subscribtion api
-spec sub(FlowSource, FlowDest) -> ok when
    FlowSource  :: flow_source() | [{topic, topic()} | {module, module()}] | topic() | module(),
    FlowDest    :: flow_dest()
                 | pid()
                 | atom()
                 | fun() | {node() | fun()}
                 | static_function() | {node(), static_function()}.

sub(FlowSource = #flow_source{module = Module, topic = Topic}, {DestType, Dest, Method}) when
        is_atom(Module),
        is_binary(Topic),
        DestType =:= 'process' orelse DestType =:= 'poolboy' orelse DestType =:= 'function' ->
    gen_server:call(?MODULE, {subscribe, FlowSource, {DestType, Dest, Method}});

% when Dest is pid() or atom
sub(FlowSource, FlowDest) when is_pid(FlowDest) orelse is_atom(FlowDest) ->
    sub(FlowSource, {process, FlowDest, info});

% when Dest is higher order functions (by default this will be executed on subscriber node (as a most common case), not producer)
sub(FlowSource, FlowDest) when is_function(FlowDest, 1) orelse is_function(FlowDest, 2) ->
    sub(FlowSource, {function, {FlowDest, is_function(FlowDest, 2)}, cast});

% when Dest is higher order functions which have to be executed on specific node
sub(FlowSource, {Node, Function}) when is_atom(Node) andalso (is_function(Function, 1) orelse is_function(Function, 2)) ->
    sub(FlowSource, {function, {Function, is_function(Function, 2)}, {Node, cast}});

% when Dest is a Module:Function([Msg | ExtraArguments])
sub(FlowSource, {Module, Function, Arguments} = MFA) when is_atom(Module) andalso is_atom(Function) andalso is_list(Arguments) ->
    sub(FlowSource, {function, gen_static_fun_dest('$local', MFA), cast});

% when Dest is mfa which have to be executed on specific node
sub(FlowSource, {Node, {Module, Function, Arguments} = MFA}) when is_atom(Node) andalso is_atom(Module) andalso is_atom(Function) andalso is_list(Arguments) ->
    sub(FlowSource, {function, gen_static_fun_dest(Node, MFA), {Node, cast}});

% when FlowSource is_atom()
sub(FlowSource, FlowDest) when is_atom(FlowSource) ->
    sub(#flow_source{module = FlowSource}, FlowDest);

% when FlowSource is_binary()
sub(FlowSource, FlowDest) when is_binary(FlowSource) ->
    sub(#flow_source{topic = FlowSource}, FlowDest);

% when FlowSource is_list
sub(FlowSource, FlowDest) when is_list(FlowSource) ->
    sub(#flow_source{
            module = case lists:keyfind(module, 1, FlowSource) of
                false -> undefined;
                {module, Data} -> Data
            end,
            topic = case lists:keyfind(topic, 1, FlowSource) of
                false -> <<"#">>;
                {topic, Data} -> Data
            end
        }, FlowDest).

% @doc internal subscribe routine
-spec subscribe(FlowSource, FlowDest) -> Result when
    FlowSource  :: flow_source(),
    FlowDest    :: flow_dest(),
    Result      :: term(). % todo

subscribe(#flow_source{module = Module, topic = Topic}, {DestType, Dest, Method}) ->
    MS = [{
        #subscriber{module = Module, topic = Topic, dest_type = DestType, dest = Dest, method = Method, _ = '_'},
        [],
        ['$_']
    }],
    EtsTid = ets:whereis(?SUBETS),
    _ = case ets:select(EtsTid, MS) of
        [] ->
            {IsFinal, Words} = is_final_topic(Topic),
            ets:insert(EtsTid, #subscriber{
                topic = Topic,
                module = Module,
                is_final_topic = IsFinal,
                words = Words,
                dest_type = DestType,
                dest = Dest,
                method = Method,
                sub_ref = gen_id()
            }),
            _ = case IsFinal of
                true ->
                    case Module of
                        undefined ->
                            lists:map(fun
                                (#topics{module = TopicModule}) when TopicModule =:= Module orelse Module =:= undefined ->
                                    ets:insert(route_table_must_present(cache_table(Module)),
                                        #cached_route{
                                            topic = Topic,
                                            dest_type = DestType,
                                            dest = Dest,
                                            method = Method,
                                            parent_topic = {?SUBETS, Topic}
                                        }
                                    );
                                (_NotMatch) ->
                                    false
                            end, ets:lookup('$erlroute_topics',Topic));
                        _NotUndefined ->
                            ets:insert(
                                route_table_must_present(cache_table(Module)),
                                #cached_route{topic = Topic, dest_type = DestType, dest = Dest, method = Method}
                            )
                    end;
                false -> todo % implement matcher for parametrized topics
            end;
        _NotEmpty ->
            false
    end.

% ================================ end of sub part =============================
% ----------------------------------- unsub part -------------------------------

-spec unsub(Target) -> ok when
    Target  :: flow_source() | [{topic, topic()} | {module, module()}] | topic() | module().

% @doc unsibscribe subscribe current process from all messages from module Module
unsub(Module) when is_atom(Module) -> unsub(#flow_source{module = Module, topic = <<"#">>}, {process, self(), info});

% @doc unsubscribe current process from messages with topic Topic from any module
unsub(Topic) when is_binary(Topic) -> unsub(#flow_source{module = undefined, topic = Topic}, {process, self(), info});

% @doc subscribe current process to messages with full-defined FlowSource ([{module, Module}, {topic, Topic}])
unsub(FlowSource) when is_list(FlowSource) -> unsub(FlowSource, {process, self(), info}).

% @doc full subscribtion api
-spec unsub(FlowSource, FlowDest) -> ok when
    FlowSource  :: flow_source() | [{topic, topic()} | {module, module()}] | topic() | module(),
    FlowDest    :: flow_dest()
                 | pid()
                 | atom()
                 | fun() | {node() | fun()}
                 | static_function() | {node(), static_function()}.

unsub(FlowSource = #flow_source{module = Module, topic = Topic}, {DestType, Dest, Method}) when
        is_atom(Module),
        is_binary(Topic),
        DestType =:= 'process' orelse DestType =:= 'poolboy' orelse DestType =:= 'function' orelse DestType =:= 'erlroute_on_other_node' ->
    gen_server:call(?MODULE, {unsubscribe, FlowSource, {DestType, Dest, Method}});

% when Dest is pid() or atom
unsub(FlowSource, FlowDest) when is_pid(FlowDest) orelse is_atom(FlowDest) ->
    unsub(FlowSource, {process, FlowDest, info});

% when Dest is higher order functions (by default this will be executed on subscriber node (as a most common case), not producer)
unsub(FlowSource, FlowDest) when is_function(FlowDest, 1) orelse is_function(FlowDest, 2) ->
    unsub(FlowSource, {function, {FlowDest, is_function(FlowDest, 2)}, cast});

% when Dest is higher order functions which have to be executed on specific node
unsub(FlowSource, {Node, Function}) when is_atom(Node) andalso (is_function(Function, 1) orelse is_function(Function, 2)) ->
    unsub(FlowSource, {function, {Function, is_function(Function, 2)}, {Node, cast}});

% when Dest is a Module:Function([Msg | ExtraArguments])
unsub(FlowSource, {Module, Function, Arguments} = MFA) when is_atom(Module) andalso is_atom(Function) andalso is_list(Arguments) ->
    unsub(FlowSource, {function, gen_static_fun_dest('$local', MFA), cast});

% when Dest is mfa which have to be executed on specific node
unsub(FlowSource, {Node, {Module, Function, Arguments} = MFA}) when is_atom(Node) andalso is_atom(Module) andalso is_atom(Function) andalso is_list(Arguments) ->
    unsub(FlowSource, {function, gen_static_fun_dest(Node, MFA), {Node, cast}});

% when FlowSource is_atom()
unsub(FlowSource, FlowDest) when is_atom(FlowSource) ->
    unsub(#flow_source{module = FlowSource}, FlowDest);

% when FlowSource is_binary()
unsub(FlowSource, FlowDest) when is_binary(FlowSource) ->
    unsub(#flow_source{topic = FlowSource}, FlowDest);

% when FlowSource is_list
unsub(FlowSource, FlowDest) when is_list(FlowSource) ->
    unsub(#flow_source{
            module = case lists:keyfind(module, 1, FlowSource) of
                false -> undefined;
                {module, Data} -> Data
            end,
            topic = case lists:keyfind(topic, 1, FlowSource) of
                false -> <<"#">>;
                {topic, Data} -> Data
            end
        }, FlowDest).

% Remove one local subscriber; the caller handles cross-node propagation.
-spec delete_local_subscriber(FlowSource, FlowDest) -> ok when
    FlowSource  :: flow_source(),
    FlowDest    :: flow_dest().

delete_local_subscriber(#flow_source{module = Module, topic = Topic}, {DestType, Dest, Method}) ->
    ets:match_delete(?SUBETS, #subscriber{dest_type = DestType, dest = Dest, module = Module, method = Method, topic = Topic, _ = '_'}),
    CacheEtsSes = case Module of
        undefined  -> erlroute_cache_etses();
        _SomeModule -> [cache_table(Module)]
    end,
    lists:foreach(fun(CacheEtsName) ->
        try
            ets:match_delete(CacheEtsName, #cached_route{dest_type = DestType, topic = Topic, method = Method, dest = Dest, _ = '_'})
        catch
            _:_ -> ok
        end
    end, CacheEtsSes),
    ok.

% Remove all local process subscriptions for a pid (the caller has already
% captured the affected (topic, module) pairs it needs).
-spec delete_local_process(Pid) -> ok when
    Pid :: pid().

delete_local_process(Pid) ->
    ets:match_delete(?SUBETS, #subscriber{dest_type = process, dest = Pid, _ = '_'}),
    lists:foreach(fun(CacheEtsName) ->
        ets:match_delete(CacheEtsName, #cached_route{dest_type = process, dest = Pid, _ = '_'})
    end, erlroute_cache_etses()),
    ok.

% A monitored subscriber died: drop its subscriptions and re-propagate descriptors.
-spec unsubscribe_local_pid(Pid, ErlRouteNodes) -> ok when
    Pid             :: pid(),
    ErlRouteNodes   :: [node()].

unsubscribe_local_pid(Pid, ErlRouteNodes) ->
    Affected = lists:usort(ets:select(?SUBETS,
        [{#subscriber{dest_type = process, dest = Pid, topic = '$1', module = '$2', _ = '_'}, [], [{{'$1', '$2'}}]}])),
    Befores = [{Topic, Module, delivery_descriptor(Topic, Module)} || {Topic, Module} <- Affected],
    _ = delete_local_process(Pid),
    lists:foreach(fun({Topic, Module, Before}) ->
        propagate_local_change(Topic, Module, Before, ErlRouteNodes)
    end, Befores),
    ok.

% Remove every cross-node route we hold to Node for a (topic, module).
-spec remove_remote_routes(FlowSource, Node) -> ok when
    FlowSource  :: flow_source(),
    Node        :: node().

remove_remote_routes(#flow_source{module = Module, topic = Topic}, Node) ->
    ets:delete(?REMOTETS, {Topic, Module, Node}),
    invalidate_remote_cache(Topic, Module, Node).

-spec upsert_remote_route(FlowSource, Node, Descriptor) -> ok when
    FlowSource  :: flow_source(),
    Node        :: node(),
    Descriptor  :: delivery_descriptor().

upsert_remote_route(#flow_source{module = Module, topic = Topic}, Node, Descriptor) ->
    {DestType, Dest, Method} = case Descriptor of
        {direct, Proc, M} -> {process_on_other_node, {Node, Proc}, M};
        {pool, RouterPid} -> {erlroute_on_other_node, {Node, RouterPid}, pub_type_based}
    end,
    ets:insert(?REMOTETS, #remote_sub{
        key      = {Topic, Module, Node},
        dest_type = DestType,
        dest     = Dest,
        method   = Method,
        sub_ref  = gen_id()
    }),
    invalidate_remote_cache(Topic, Module, Node).

-spec invalidate_remote_cache(Topic, Module, Node) -> ok when
    Topic   :: topic(),
    Module  :: 'undefined' | module(),
    Node    :: node().

invalidate_remote_cache(Topic, Module, Node) ->
    CacheEtses = case Module of
        undefined   -> erlroute_cache_etses();
        _SomeModule -> [cache_table(Module)]
    end,
    lists:foreach(fun(CacheEts) ->
        try
            ets:match_delete(CacheEts, #cached_route{topic = Topic, dest_type = process_on_other_node, dest = {Node, '_'}, _ = '_'}),
            ets:match_delete(CacheEts, #cached_route{topic = Topic, dest_type = erlroute_on_other_node, dest = {Node, '_'}, _ = '_'})
        catch
            _:_ -> ok
        end
    end, CacheEtses),
    ok.

% ================================ end of sub part =============================

% ---------------------------------other functions -----------------------------

-spec post_hitcache_routine(Module, Process, Line, PubType, Topic, Payload, EtsName, WhoGetAlready, PostRef, Scope) -> Result when
    Module          :: module(),
    Process         :: pid(),
    Line            :: pos_integer(),
    PubType         :: pub_type(),
    Topic           :: topic(),
    Payload         :: payload(),
    EtsName         :: atom(),
    WhoGetAlready   :: pub_result(),
    PostRef         :: undefined | reference(),
    Scope           :: scope(),
    Result          :: term(). % todo

post_hitcache_routine(Module, Process, Line, PubType, Topic, Payload, EtsName, WhoGetAlready, PostRef, Scope) ->
    Words = split_topic(Topic),
    ProcessToWrite =
        try
            case is_pid(Process) of
                true ->
                    case process_info(Process, [registered_name]) of
                        [{registered_name, SomeName}] when is_atom(SomeName) ->
                            SomeName;
                        [{registered_name, []}] ->
                            '$erlroute_unregistered';
                        undefined ->
                            '$erlroute_unregistered_and_dead';
                        [] ->
                            '$erlroute_unregistered'
                    end;
                false ->
                    Process
            end
        catch
            _:_ ->
                Process
        end,
    _ = ets:insert('$erlroute_topics', #topics{
        topic = Topic,
        words = Words,
        module = Module,
        line = Line,
        process = ProcessToWrite
    }),
    lists:foldl(
        fun(#subscriber{module = SubscriberModule, dest_type = DestType, dest = Dest, method = Method, sub_ref = SubRef}, Acc) ->
            case lists:member({Dest, Method}, WhoGetAlready) of
                false when (PostRef =:= undefined orelse PostRef > SubRef) andalso (Module =:= SubscriberModule orelse SubscriberModule =:= undefined) ->
                    ToInsert = #cached_route{
                        topic = Topic,
                        dest_type = DestType,
                        dest = Dest,
                        method = Method,
                        parent_topic = {?SUBETS, Topic}
                    },
                    Toreturn = send([ToInsert], Payload, Module, Process, Line, PubType, Topic, EtsName, [], Scope),
                    ets:insert(route_table_must_present(EtsName), ToInsert),
                    Toreturn;
                _NoMatch ->
                    Acc
            end
        end, WhoGetAlready, ets:lookup(?SUBETS, Topic) ++ remote_subs_as_subscribers(Topic, Module)
    ).


% @doc generate ets name for Module for completed topics
-spec cache_table(Module) -> EtsName when
    Module  ::  module(),
    EtsName ::  atom().

cache_table(Module) when is_atom(Module)->
    list_to_atom("$erlroute_cache_" ++ atom_to_list(Module)).

% @doc Check if ets routing table is present, on falure - let's create it
-spec route_table_must_present (EtsName) -> Result when
      EtsName   ::  atom(),
      Result    ::  ets:tid().

route_table_must_present(EtsName) ->
    case ets:whereis(EtsName) of
        undefined ->
            case whereis(?SERVER) == self() of
                true ->
                    ets:new(EtsName, [bag, public,
                        {read_concurrency, true},
                        {keypos, #cached_route.topic},
                        named_table
                    ]);
                false ->
                    gen_server:call(?SERVER, {regtable, EtsName})
            end;
       Tid ->
           Tid
   end.

% @doc check is this topic in final condition or not.
% if it contain * or ! it means this is parametrized topic
-spec is_final_topic(Topic) -> Result when
    Topic :: topic(),
    Result :: {boolean(), Words},
    Words :: 'undefined' | nonempty_list().

is_final_topic(<<$*>>) -> {true, undefined};
is_final_topic(<<$#>>) -> {true, undefined};
is_final_topic(Topic) ->
    case binary:match(Topic, [<<"*">>,<<"#">>]) of
        nomatch -> {true, undefined};
        _ -> {false, split_topic(Topic)}
    end.

% @doc split binary topic to the list
% binary:split/2 doesn't work well if contain pattern like .*
-spec split_topic(Key) -> Result when
    Key :: binary(),
    Result :: nonempty_list().

split_topic(Bin) ->
    split_topic(Bin, [], []).

-spec split_topic(Current, WAcc, ResultAcc) -> Result when
    Current     :: binary(),
    WAcc        :: list(),
    ResultAcc   :: list(),
    Result      :: nonempty_list().

split_topic(<<>>, WAcc, Result) ->
    lists:reverse([lists:reverse(WAcc)|Result]);
split_topic(<<2#00101110:8, Rest/binary>>, WAcc, Result) ->
    split_topic(Rest, [], [lists:reverse(WAcc)|Result]);
split_topic(<<Char:8, Rest/binary>>, WAcc, Result) ->
    split_topic(Rest, [Char|WAcc], Result).

% @doc Generate unique id
-spec gen_id() -> Result when
    Result      :: integer().

gen_id() -> erlang:monotonic_time().

-spec gen_static_fun_dest(Node, StaticFunction) -> Result when
    Node            :: '$local' | node(),
    StaticFunction  :: static_function(),
    Result          :: fun_dest().

gen_static_fun_dest('$local', {Module, Function, PredefinedArgs} = MFA) ->
    ExtraArgsLength = length(PredefinedArgs),
    case erlang:function_exported(Module, Function, ExtraArgsLength + 2) of
        true ->
            {MFA, true};
        false ->
            case erlang:function_exported(Module, Function, ExtraArgsLength + 1) of
                true ->
                    {MFA, false};
                false ->
                    throw(unknown_function)
            end
    end;
gen_static_fun_dest(Node, MFA) ->
    try
        gen_static_fun_dest('$local', MFA)
    catch
        _:_ ->
            erpc:call(Node, ?MODULE, gen_static_fun_dest, ['$local', MFA], ?DEFAULT_TIMEOUT_FOR_RPC)
    end.

% Fire-and-forget control message to erlroute on each peer. Async — no
% synchronous round-trip — so cross-node propagation never blocks the erlroute
% control plane on a slow/unreachable peer (the dist send buffer is the proper
% back-pressure point). Dropped silently where erlroute isn't registered.
-spec broadcast_to_nodes(Nodes, Msg) -> ok when
    Nodes :: [node()],
    Msg   :: term().

broadcast_to_nodes(Nodes, Msg) ->
    lists:foreach(fun(Node) -> erlang:send({?MODULE, Node}, Msg) end, Nodes).

% Bare discovery ping: "I'm an erlroute node, sync with me". Carries no payload
% and does not by itself create any state on the receiver beyond prompting it to
% sync. Dropped silently where erlroute isn't running.
-spec ping_node(Node :: node()) -> ok.

ping_node(Node) ->
    _ = erlang:send({?MODULE, Node}, {erlroute_ping, node()}),
    ok.

-spec ping_nodes(Nodes :: [node()]) -> ok.

ping_nodes(Nodes) ->
    broadcast_to_nodes(Nodes, {erlroute_ping, node()}).

-spec announce_to(Node :: node()) -> ok.

announce_to(Node) ->
    _ = erlang:send({?MODULE, Node}, {erlroute_sync, node(), local_descriptors()}),
    ok.

-spec apply_remote_descriptors(Node, Descriptors) -> ok when
    Node        :: node(),
    Descriptors :: [{flow_source(), delivery_descriptor()}].

apply_remote_descriptors(Node, Descriptors) ->
    lists:foreach(fun({#flow_source{} = FlowSource, Descriptor}) ->
        case Descriptor of
            none -> remove_remote_routes(FlowSource, Node);
            _    -> upsert_remote_route(FlowSource, Node, Descriptor)
        end
    end, Descriptors).

-spec unsubscribe_node(Node) -> Result when
    Node    :: node(),
    Result  :: term(). % todo

unsubscribe_node(Node) ->
    ets:match_delete(?REMOTETS, #remote_sub{key = {'_', '_', Node}, _ = '_'}),
    lists:foreach(fun(CacheEtsName) ->
        ets:match_delete(CacheEtsName, #cached_route{dest_type = erlroute_on_other_node, dest = {Node, '_'}, _ = '_'}),
        ets:match_delete(CacheEtsName, #cached_route{dest_type = process_on_other_node, dest = {Node, '_'}, _ = '_'})
    end, erlroute_cache_etses()).

-spec erlroute_cache_etses() -> Result when
    Result  :: [atom()].

erlroute_cache_etses() ->
    lists:foldl(fun
        (EtsName, Acc) when is_atom(EtsName) ->
            case atom_to_binary(EtsName) of
                <<"$erlroute_cache_", Module/binary>> ->
                    try
                        _ = binary_to_existing_atom(Module),
                        [EtsName | Acc]
                    catch
                        _:_ -> Acc
                    end;
                _Other ->
                    Acc
            end;
        (_EtsTid, Acc) -> Acc
        end,
        [],
        ets:all()
    ).

-spec local_descriptors() -> [{flow_source(), delivery_descriptor()}].

local_descriptors() ->
    Groups = lists:foldl(fun
        (#subscriber{dest_type = DestType, topic = Topic, module = Module, dest = Dest, method = Method}, Acc)
          when DestType =:= process; DestType =:= poolboy; DestType =:= function ->
            maps:update_with({Topic, Module},
                fun(Subs) -> [{DestType, Dest, Method} | Subs] end,
                [{DestType, Dest, Method}], Acc);
        (_RemoteRoute, Acc) ->
            Acc
    end, #{}, ets:tab2list(?SUBETS)),
    maps:fold(fun({Topic, Module}, Subs, Acc) ->
        FlowSource = #flow_source{module = Module, topic = Topic},
        [{FlowSource, descriptor_from_subscribers(Subs, Topic)} | Acc]
    end, [], Groups).

% --------------------------- cross-node delivery -----------------------------

% Local subscribers (not routes we hold to other nodes) for a (topic, module).
-spec local_subscribers(Topic, Module) -> [{dest_type(), dest(), delivery_method()}] when
    Topic   :: topic(),
    Module  :: 'undefined' | module().

local_subscribers(Topic, Module) ->
    ets:select(?SUBETS,
        [{#subscriber{topic = Topic, module = Module, dest_type = '$1', dest = '$2', method = '$3', _ = '_'},
          [{'andalso', {'=/=', '$1', process_on_other_node}, {'=/=', '$1', erlroute_on_other_node}}],
          [{{'$1', '$2', '$3'}}]}]).

% How remote nodes should deliver this (topic, module) to us (see the type).
-spec delivery_descriptor(Topic, Module) -> delivery_descriptor() when
    Topic   :: topic(),
    Module  :: 'undefined' | module().

delivery_descriptor(Topic, Module) ->
    descriptor_from_subscribers(local_subscribers(Topic, Module), Topic).

% The single source of truth for the direct-vs-pool decision, shared by the live
% subscribe path (delivery_descriptor/2) and the join-time pull path
% (local_descriptors/0): one lone process subscriber -> direct send;
% anything else (2+, or a non-process subscriber) -> via the assigned router.
-spec descriptor_from_subscribers(Subs, Topic) -> delivery_descriptor() when
    Subs    :: [{dest_type(), dest(), delivery_method()}],
    Topic   :: topic().

descriptor_from_subscribers([], _Topic) ->
    none;
descriptor_from_subscribers([{process, Proc, Method}], _Topic) ->
    {direct, Proc, Method};
descriptor_from_subscribers(_MultipleOrNonProcess, Topic) ->
    {pool, assign_router(Topic)}.

% Re-propagate to remotes only if the local change flipped the descriptor.
-spec propagate_local_change(Topic, Module, Before, ErlRouteNodes) -> ok when
    Topic           :: topic(),
    Module          :: 'undefined' | module(),
    Before          :: delivery_descriptor(),
    ErlRouteNodes   :: [node()].

propagate_local_change(Topic, Module, Before, ErlRouteNodes) ->
    After = delivery_descriptor(Topic, Module),
    maybe_propagate_descriptor(Before, After, #flow_source{module = Module, topic = Topic}, ErlRouteNodes).

-spec maybe_propagate_descriptor(Before, After, FlowSource, ErlRouteNodes) -> ok when
    Before          :: delivery_descriptor(),
    After           :: delivery_descriptor(),
    FlowSource      :: flow_source(),
    ErlRouteNodes   :: [node()].

maybe_propagate_descriptor(Same, Same, _FlowSource, _ErlRouteNodes) ->
    ok;
maybe_propagate_descriptor(_Before, none, FlowSource, ErlRouteNodes) ->
    broadcast_to_nodes(ErlRouteNodes, {remove_remote_route, FlowSource, node()});
maybe_propagate_descriptor(_Before, After, FlowSource, ErlRouteNodes) ->
    broadcast_to_nodes(ErlRouteNodes, {set_remote_route, FlowSource, After, node()}).

% ------------------------------- router pool ---------------------------------

% @doc Configured number of routers in the local pool (>= 1).
-spec router_pool_size() -> pos_integer().

router_pool_size() ->
    erlang:max(1, application:get_env(erlroute, router_pool_size, ?DEFAULT_ROUTER_POOL_SIZE)).

% @doc The router pid assigned to a topic. The binding is sticky — once a topic
% is bound to a router, all its subscribers (and so per-topic message order)
% stay on that router — and assigned round-robin on first use. Kept in a public
% ETS table (not a pure hash) so it can be rebalanced later, e.g. by message
% queue depth, by overwriting the binding and re-propagating. Resolves
% concurrent first-use via insert_new.
-spec assign_router(Topic) -> pid() when
    Topic :: topic().

assign_router(Topic) when is_binary(Topic) ->
    case ets:lookup(?ROUTERETS, Topic) of
        [{Topic, Pid}] ->
            Pid;
        [] ->
            Routers = ets:lookup_element(?ROUTERETS, '$routers', 2),
            Seq = ets:update_counter(?ROUTERETS, '$next', 1),
            Pid = element((Seq - 1) rem tuple_size(Routers) + 1, Routers),
            case ets:insert_new(?ROUTERETS, {Topic, Pid}) of
                true  -> Pid;
                false -> ets:lookup_element(?ROUTERETS, Topic, 2)  % lost the race
            end
    end.

-spec remote_subs_as_subscribers(Topic, Module) -> [#subscriber{}] when
    Topic   :: topic(),
    Module  :: 'undefined' | module().

remote_subs_as_subscribers(Topic, Module) ->
    ExactMS = [{#remote_sub{key = {Topic, Module, '_'}, _ = '_'}, [], ['$_']}],
    AnyMS   = [{#remote_sub{key = {Topic, undefined, '_'}, _ = '_'}, [], ['$_']}],
    Exact   = ets:select(?REMOTETS, ExactMS),
    Any     = case Module of
        undefined -> [];
        _         -> ets:select(?REMOTETS, AnyMS)
    end,
    [remote_sub_to_subscriber(R) || R <- Exact ++ Any].

-spec remote_sub_to_subscriber(RemoteSub) -> #subscriber{} when
    RemoteSub :: #remote_sub{}.

remote_sub_to_subscriber(#remote_sub{key = {Topic, Module, _Node}, dest_type = DestType, dest = Dest, method = Method, sub_ref = SubRef}) ->
    #subscriber{topic = Topic, module = Module, is_final_topic = true, dest_type = DestType, dest = Dest, method = Method, sub_ref = SubRef}.

% @doc if subsctiber is a process PId, let's establish monitor and unsubscribe when subscriber dies.
% if subscriber is a registered process, we will keep subscribtion up, as another process may be registered with the same name, so
% no-resubscribtion will be needed.
% @end

-spec may_establish_monitor(Dest, Monitors) -> Result when
    Dest        :: flow_dest(),
    Monitors    :: #{pid() => reference()},
    Result      :: #{pid() => reference()}.

may_establish_monitor({process, Proc, _DeliveryMethod}, Monitors) when is_pid(Proc) ->
    case maps:is_key(Proc, Monitors) of
        true  -> Monitors;
        false -> maps:put(Proc, erlang:monitor(process, Proc), Monitors)
    end;

may_establish_monitor(_NotMatch, Monitors) -> Monitors.

% Remove the monitor for Proc if it has no remaining process subscriptions in SUBETS.
-spec may_release_monitor(FlowDest, Monitors) -> Monitors when
    FlowDest  :: flow_dest(),
    Monitors  :: #{pid() => reference()}.

may_release_monitor({process, Proc, _Method}, Monitors) when is_pid(Proc) ->
    case ets:match(?SUBETS, #subscriber{dest_type = process, dest = Proc, _ = '_'}) of
        [] ->
            case maps:take(Proc, Monitors) of
                {Ref, NewMonitors} -> erlang:demonitor(Ref, [flush]), NewMonitors;
                error              -> Monitors
            end;
        _ ->
            Monitors
    end;
may_release_monitor(_FlowDest, Monitors) -> Monitors.



