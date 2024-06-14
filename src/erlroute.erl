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
        full_async_pub/5,
        full_sync_pub/5,
        sub/2,
        sub/1,
        unsub/2,
        unsub/1,
        cache_table/1, % export support function for parse_transform
        post_hitcache_routine/9,
        gen_static_fun_dest/2,
        fetch_flow_dests_and_sources/0,
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
    _ = net_kernel:monitor_nodes(true),
    Nodes = discover_erlroute_nodes(),
    _ = fetch_subscribtions_from_remote_nodes(Nodes),
    {ok, #erlroute_state{erlroute_nodes = Nodes}}.

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

handle_call({subscribe, FlowSource, FlowDest}, _From, #erlroute_state{erlroute_nodes = ErlrouteNodes, monitors = Monitors} = State) ->
    ProbablyMoreMonitors = may_establish_monitor(FlowDest, Monitors),
    Result = subscribe(FlowSource, FlowDest),
    _ = erpc:multicall(ErlrouteNodes, erlang, send, [erlroute, {subscribe_from_remote, FlowSource, FlowDest, node()}], ?DEFAULT_TIMEOUT_FOR_RPC),
    {reply, Result, State#erlroute_state{monitors = ProbablyMoreMonitors}};

handle_call({unsubscribe, FlowSource, FlowDest}, _From, #erlroute_state{erlroute_nodes = ErlRouteNodes} = State) ->
    unsubscribe(FlowSource, FlowDest, ErlRouteNodes),
    {reply, ok, State};

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
    Message     :: {nodeup, node()} | {nodedown, node()} | {subscribe_from_remote, flow_source(), flow_dest(), node()},
    State       :: erlroute_state(),
    Result      :: {noreply, erlroute_state()}.

% todo: populate to that node our subscribtions
handle_info({nodeup, Node}, #erlroute_state{erlroute_nodes = Nodes} = State) ->
    case node() =/= Node of
        true ->
            try erpc:call(Node, erlang, function_exported, [?MODULE, start_link, 0], ?DEFAULT_TIMEOUT_FOR_RPC) of
                true ->
                    _ = fetch_subscribtions_from_remote_nodes([Node]),
                    {noreply, State#erlroute_state{erlroute_nodes = lists:uniq([Node | Nodes])}};
                false ->
                    {noreply, State#erlroute_state{erlroute_nodes = Nodes -- [Node]}}
            catch
                _:_ ->
                    {noreply, State}
            end;
        false ->
            {noreply, State}
    end;

% todo: unsubscribe that node after some timeout
handle_info({nodedown, Node}, #erlroute_state{erlroute_nodes = Nodes} = State) ->
    _ = unsubscribe_node(Node),
    {noreply, State#erlroute_state{erlroute_nodes = Nodes -- [Node]}};

handle_info({subscribe_from_remote, FlowSource, {process, Proc, info}, Node}, State) ->
    _ = subscribe(FlowSource, {process_on_other_node, {Node, Proc}, info}),
    {noreply, State};

handle_info({subscribe_from_remote, FlowSource, _FlowDest, Node}, State) ->
    _ = subscribe(FlowSource, {erlroute_on_other_node, Node, pub_type_based}),
    {noreply, State};

handle_info({'DOWN', _Ref, process, Pid, _Reason}, #erlroute_state{monitors = Monitors, erlroute_nodes = ErlRouteNodes} = State) ->
    unsubscribe(all, {process, Pid}, ErlRouteNodes),
    {noreply, State#erlroute_state{monitors = maps:remove(Pid, Monitors)}};

% @doc case for unknown messages
handle_info(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle_info with message ~p\n",[Msg]),
    {noreply, State}.

%-----------end of handle_info-------------

-spec terminate(Reason, State) -> term() when
    Reason      :: 'normal' | 'shutdown' | {'shutdown',term()} | term(),
    State       :: term().

terminate(Reason, State) ->
    {noreply, Reason, State}.

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
        []
    ),
    PostRef = gen_id(),
    spawn(?MODULE, post_hitcache_routine, [Module, Process, Line, PubType, Topic, Payload, EtsName, WhoGetWhileSync, PostRef]),
    WhoGetWhileSync;

pub(Module, Process, Line, Topic, Payload, async, EtsName) ->
    spawn(?MODULE, pub, [Module, Process, Line, Topic, Payload, sync, EtsName]),
    [];

pub(Module, Process, Line, Topic, Payload, sync = PubType, EtsName) ->
    post_hitcache_routine(
        Module,
        Process,
        Line,
        PubType,
        Topic,
        Payload,
        EtsName,
        load_routing_and_send(
            ets:whereis(EtsName),
            EtsName,
            Module,
            Process,
            Line,
            PubType,
            Topic,
            Payload,
            []
        ),
        undefined
    ).

-spec load_routing_and_send(EtsTid, EtsName, Module, Process, Line, PubType, Topic, Payload, Acc) -> Result when
    EtsTid          :: undefined | ets:tid(),
    EtsName         :: atom(),
    Module          :: module(),
    Process         :: proc(),
    Line            :: pos_integer(),
    PubType         :: pub_type(),
    Topic           :: topic(),
    Payload         :: payload(),
    Acc             :: pub_result(),
    Result          :: pub_result().

load_routing_and_send(undefined, _EtsName, _Module, _Process, _Line, _PubType, _Topic, _Payload, Acc) -> Acc;
load_routing_and_send(EtsTid, EtsName, Module, Process, Line, PubType, Topic, Payload, Acc) ->
    try ets:lookup(EtsTid, Topic) of
        [] when Topic =/= <<"#">> ->
            load_routing_and_send(EtsTid, EtsName, Module, Process, Line, PubType, <<"#">>, Payload, Acc);
        [] ->
            Acc;
        Routes when Topic =/= <<"#">> ->
            % send to wildcard-topic subscribers
            load_routing_and_send(EtsTid, EtsName, Module, Process, Line, PubType, <<"#">>, Payload, send(Routes, Payload, Module, Process, Line, PubType, Topic, EtsName, Acc));
        Routes ->
            send(Routes, Payload, Module, Process, Line, PubType, Topic, EtsName, Acc)
    catch
        _:_ ->
            Acc
    end.

-spec send(Routes, Payload, Module, Process, Line, PubType, Topic, EtsName, Acc) -> Result when
    Routes          :: [cached_route()],
    Payload         :: payload(),
    Module          :: module(),
    Process         :: proc(),
    Line            :: pos_integer(),
    PubType         :: pub_type(),
    Topic           :: topic(),
    EtsName         :: atom(),
    Acc             :: pub_result(),
    Result          :: pub_result().

% sending to standart process
send([#cached_route{dest_type = 'process', method = Method, dest = Dest}|T], Payload, Module, Process, Line, PubType, Topic, EtsName, Acc) ->
    case Method of
        info -> Dest ! Payload;
        cast -> gen_server:cast(Dest, Payload);
        call -> gen_server:call(Dest, Payload)
    end,
    send(T, Payload, Module, Process, Line, PubType, Topic, EtsName, [{Dest, Method} | Acc]);

% apply process
send([#cached_route{dest_type = 'function', method = Method, dest = {Function, ShellIncludeTopic} = Dest}|T], Payload, Module, Process, Line, PubType, Topic, EtsName, Acc) ->
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
    end,
    send(T, Payload, Module, Process, Line, PubType, Topic, EtsName, [{Dest, Method} | Acc]);

% sending to poolboy pool
send([#cached_route{dest_type = 'poolboy', method = Method, dest = PoolName}|T], Payload, Module, Process, Line, PubType, Topic, EtsName, Acc) ->
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
    send(T, Payload, Module, Process, Line, PubType, Topic, EtsName, [{PoolName, Method} | Acc]);

send([#cached_route{dest_type = 'process_on_other_node', method = info, dest = {_Node, Proc} = Dest}|T], Payload, Module, Process, Line, PubType, Topic, EtsName, Acc) when is_pid(Proc) ->
	erlang:send(Proc, Payload),
    send(T, Payload, Module, Process, Line, PubType, Topic, EtsName, [{Dest, info} | Acc]);

send([#cached_route{dest_type = 'process_on_other_node', method = info, dest = {Node, Proc} = Dest}|T], Payload, Module, Process, Line, PubType, Topic, EtsName, Acc) when is_atom(Proc) ->
	erlang:send({Proc, Node}, Payload),
    send(T, Payload, Module, Process, Line, PubType, Topic, EtsName, [{Dest, info} | Acc]);

% sending to erlroute on other nodes
send([#cached_route{dest_type = 'erlroute_on_other_node', method = Method, dest = Node}|T], Payload, Module, Process, Line, PubType, Topic, EtsName, Acc) ->
    case PubType of
        async ->
            erpc:cast(Node, erlroute, pub, [Module, Process, Line, Topic, Payload, sync, EtsName]);
        _ ->
            try
                erpc:call(Node, erlroute, pub, [Module, Process, Line, Topic, Payload, sync, EtsName], ?DEFAULT_TIMEOUT_FOR_RPC)
            catch
                _Error:Reason ->
                    error_logger:error_msg("erlroute erpc:call to node ~p when apply ~p:~p(~p) failed with reason ~p\n",[Node, ?MODULE, pub, [Module, Process, Line, Topic, Payload, sync, EtsName], Reason])
            end
    end,
    send(T, Payload, Module, Process, Line, PubType, Topic, EtsName, [{Node, Method} | Acc]);

% final clause for empty list
send([], _Payload, _Module, _Process, _Line, _PubType, _Topic, _EtsName, Acc) -> Acc.

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
        DestType =:= 'process' orelse DestType =:= 'poolboy' orelse DestType =:= 'function' orelse DestType =:= 'erlroute_on_other_node' orelse DestType =:= 'process_on_other_node' ->
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

% this function usually call from gen_server
-spec unsubscribe(FlowSource, FlowDest, ErlRouteNodes) -> Result when
    FlowSource      :: flow_source() | all,
    FlowDest        :: {process, proc()}| {function, fun_dest()} | flow_dest(),
    ErlRouteNodes   :: [node()],
    Result          :: term().

unsubscribe(all, {DestType, Dest}, ErlRouteNodes) ->
    TopicsAndModules = ets:select(
        ?SUBETS,
        [{
            #subscriber{dest_type = DestType, dest = Dest, _ = '_'},
            [],
            ['$_']
        }]
    ),
    ets:match_delete(?SUBETS, #subscriber{dest_type = DestType, dest = Dest, _ = '_'}),
    lists:foreach(fun(CacheEtsName) ->
        ets:match_delete(CacheEtsName, #cached_route{dest_type = DestType, dest = Dest, _ = '_'})
    end, erlroute_cache_etses()),

    % cleanup on other nodes if we don't have other subscribers with the same combination of Topic / Module
    lists:foreach(fun(#subscriber{topic = Topic, module = Module}) ->
        case ets:match(?SUBETS, #subscriber{topic = Topic, module = Module, _ = '_'}) of
            [] ->
                try
                    erpc:multicast(
                        ErlRouteNodes,
                        ?MODULE,
                        unsub,
                        [#flow_source{topic = Topic, module = Module}, {erlroute_on_other_node, node(), pub_type_based}]
                    )
                catch
                    _Error:Reason ->
                        error_logger:error_msg("erlroute erpc:multicast to nodes ~p when apply ~p:~p(~p) failed with reason ~p\n",[ErlRouteNodes, ?MODULE, unsub, [#flow_source{topic = Topic, module = Module}, {erlroute_on_other_node, node(), pub_type_based}], Reason])
                end;
            _HaveRecord ->
                false
        end
    end, TopicsAndModules);

unsubscribe(#flow_source{module = Module, topic = Topic}, {DestType, Dest, DeliveryMethod}, ErlRouteNodes) ->
    ets:match_delete(?SUBETS, #subscriber{dest_type = DestType, dest = Dest, module = Module, method = DeliveryMethod, topic = Topic, _ = '_'}),

    CacheEtsSes = case Module of
        undefined ->
            erlroute_cache_etses();
        _SomeModule ->
            [cache_table(Module)]
    end,

    lists:foreach(fun(CacheEtsName) ->
        % cache table probably not exist yet, so wrapping in a try/catch
        try
            ets:match_delete(CacheEtsName, #cached_route{dest_type = DestType, topic = Topic, method = DeliveryMethod, dest = Dest, _ = '_'})
        catch
            _:_ ->
                ok
        end
    end, CacheEtsSes),

    % cleanup on other nodes if we don't have other subscribers with the same combination of Topic / Module
    case DestType =/= erlroute_on_other_node of
        true ->
            case ets:match(?SUBETS, #subscriber{topic = Topic, module = Module, _ = '_'}) of
                [] ->
                    erpc:multicast(
                        ErlRouteNodes,
                        ?MODULE,
                        unsub,
                        [#flow_source{topic = Topic, module = Module}, {erlroute_on_other_node, node(), pub_type_based}]
                    );
                _HaveRecord ->
                    false
            end;
        false ->
            false
    end;

unsubscribe(FlowSource, {DestType, Dest, _DeliveryMethod}, ErlRouteNodes) -> unsubscribe(FlowSource, {DestType, Dest}, ErlRouteNodes).

% ================================ end of sub part =============================

% ---------------------------------other functions -----------------------------

-spec post_hitcache_routine(Module, Process, Line, PubType, Topic, Payload, EtsName, WhoGetAlready, PostRef) -> Result when
    Module          :: module(),
    Process         :: pid(),
    Line            :: pos_integer(),
    PubType         :: pub_type(),
    Topic           :: topic(),
    Payload         :: payload(),
    EtsName         :: atom(),
    WhoGetAlready   :: pub_result(),
    PostRef         :: undefined | reference(),
    Result          :: term(). % todo

post_hitcache_routine(Module, Process, Line, PubType, Topic, Payload, EtsName, WhoGetAlready, PostRef) ->
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
                    Toreturn = send([ToInsert], Payload, Module, Process, Line, PubType, Topic, EtsName, []),
                    ets:insert(route_table_must_present(EtsName), ToInsert),
                    Toreturn;
                _NoMatch ->
                    Acc
            end
        end, WhoGetAlready, ets:lookup(?SUBETS, Topic)
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

% @doc Discrover erlang nodes which have erlroute
-spec discover_erlroute_nodes() -> Result when
    Result  :: [node()].

discover_erlroute_nodes() ->
    case node() of
        nonode@nohost ->
            [];
        _SomeNodeName ->
            Nodes = nodes(),
            case length(Nodes) of
                0 ->
                    [];
                _NotNull ->
                    lists:foldl(fun
                        ({Node, {ok, true}}, Acc) ->
                            [Node | Acc];
                        ({_Node, {ok, false}}, Acc) ->
                            Acc;
                        ({_Node, _OtherResp}, Acc) ->
                            Acc
                        end,
                        [],
                        lists:zip(
                            Nodes,
                            erpc:multicall(
                              Nodes,
                              erlang,
                              function_exported,
                              [?MODULE, start_link, 0],
                              ?DEFAULT_TIMEOUT_FOR_RPC
                            )
                        )
                    )
            end
    end.

-spec fetch_subscribtions_from_remote_nodes(Nodes) -> Result when
    Nodes   :: [node()],
    Result  :: term().

fetch_subscribtions_from_remote_nodes([]) -> false;
fetch_subscribtions_from_remote_nodes(Nodes) ->
    lists:foreach(fun
        ({_Node, {ok, []}}) ->
            false;
        ({Node, {ok, FlowSources}}) when is_list(FlowSources) ->
            lists:map(fun
                (#flow_source{} = FlowSource) ->
                    subscribe(FlowSource, {erlroute_on_other_node, Node, pub_type_based});
                ({Proc, #flow_source{} = FlowSource}) ->
                    subscribe(FlowSource, {process_on_other_node, {Node, Proc}, info})
                end,
            FlowSources);
        ({_Node, _OtherResp}) ->
            false
        end,
        lists:zip(
            Nodes,
            erpc:multicall(
              Nodes,
              erlroute,
              fetch_flow_dests_and_sources,
              [],
              ?DEFAULT_TIMEOUT_FOR_RPC
            )
        )
    ).

-spec unsubscribe_node(Node) -> Result when
    Node    :: node(),
    Result  :: term(). % todo

unsubscribe_node(Node) ->
    ets:match_delete(?SUBETS, #subscriber{dest_type = erlroute_on_other_node, dest = Node, _ = '_'}),
    ets:match_delete(?SUBETS, #subscriber{dest_type = process_on_other_node, dest = {Node, '_'}, _ = '_'}),
    lists:foreach(fun(CacheEtsName) ->
        ets:match_delete(CacheEtsName, #cached_route{dest_type = erlroute_on_other_node, dest = Node, _ = '_'}),
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

-spec fetch_flow_dests_and_sources() -> Result when
    Result      :: [{proc(), flow_source()} | flow_source()].

fetch_flow_dests_and_sources() ->
    lists:foldl(fun
        (#subscriber{dest_type = erlroute_on_other_node}, Acc) ->
            Acc;
        (#subscriber{dest_type = process_on_other_node}, Acc) ->
            Acc;
        (#subscriber{dest_type = process, method = info, dest = Proc, topic = Topic, module = Module}, Acc) ->
            [{Proc, #flow_source{module = Module, topic = Topic}} | Acc];
        (#subscriber{topic = Topic, module = Module}, Acc) ->
            [#flow_source{module = Module, topic = Topic} | Acc]
        end,
    [], ets:tab2list(?SUBETS)).

% @doc if subsctiber is a process PId, let's establish monitor and unsubscribe when subscriber dies.
% if subscriber is a registered process, we will keep subscribtion up, as another process may be registered with the same name, so
% no-resubscribtion will be needed.
% @end

-spec may_establish_monitor(Dest, Monitors) -> Result when
    Dest        :: flow_dest(),
    Monitors    :: #{pid() => reference()},
    Result      :: #{pid() => reference()}.

may_establish_monitor({process, Proc, _DeliveryMethod}, Monitors) when is_pid(Proc) ->
    maps:put(Proc, erlang:monitor(process, Proc), Monitors);

may_establish_monitor(_NotMatch, Monitors) -> Monitors.



