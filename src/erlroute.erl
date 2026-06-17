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
-define(PIDETS,  '$erlroute_pid_index').
-define(ROUTERETS, '$erlroute_routers').

-define(DEFAULT_TIMEOUT_FOR_RPC, 1000).
-define(SERVER, ?MODULE).

-include("erlroute.hrl").

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([
        start_link/0,
        stop/0, stop/1
    ]).

-export([
        pub/2,
        pub/3,
        pub_local/2,
        sub/1,
        sub/2,
        unsub/1,
        unsub/2,
        gen_static_fun_dest/2,
        assign_router/1,
        router_pool_size/0
    ]).

% ----------------------------- gen_server part --------------------------------

-spec start_link() -> Result when
    Result      :: {ok, Pid} | ignore | {error, Error},
    Pid         :: pid(),
    Error       :: {already_started,Pid} | term().

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec stop() -> ok.

stop() -> stop(sync).

-spec stop(Type) -> ok when
    Type :: 'sync' | 'async'.

stop(sync)  -> gen_server:stop(?SERVER);
stop(async) -> gen_server:cast(?SERVER, stop).

-spec init([]) -> {ok, erlroute_state()}.

init([]) ->
    process_flag(trap_exit, true),
    % set table: {Topic :: topic(), Subs :: [sub_spec()]}
    _ = ets:new(?SUBETS,   [set, public, {read_concurrency, true}, named_table]),
    % bag table: {Pid :: pid(), Topic :: topic()} — reverse index for pid-cleanup
    _ = ets:new(?PIDETS,   [bag, public, {read_concurrency, true}, named_table]),
    _ = ets:new(?ROUTERETS, [set, public, named_table, {read_concurrency, true}]),
    % bag table keyed by #remote_sub.topic
    _ = ets:new(?REMOTETS, [bag, public, named_table, {read_concurrency, true},
                             {keypos, #remote_sub.topic}]),
    Routers = start_routers(router_pool_size()),
    true = ets:insert(?ROUTERETS, [{'$routers', list_to_tuple(Routers)}, {'$next', 0}]),
    _ = net_kernel:monitor_nodes(true),
    _ = ping_nodes(nodes()),
    {ok, #erlroute_state{}}.

-spec start_routers(N :: pos_integer()) -> [pid()].

start_routers(N) ->
    [begin {ok, Pid} = erlroute_router:start_link(), Pid end || _ <- lists:seq(1, N)].

%--------------handle_call-----------------

-spec handle_call(Message, From, State) -> Result when
    Message     :: term(),
    From        :: {pid(), Tag},
    Tag         :: term(),
    State       :: erlroute_state(),
    Result      :: {reply, term(), erlroute_state()}.

handle_call({subscribe, Topic, FlowDest}, _From,
            #erlroute_state{erlroute_nodes = ErlrouteNodes, monitors = Monitors} = State) ->
    Before = delivery_descriptor(Topic),
    subscribe(Topic, FlowDest),
    _ = propagate_local_change(Topic, Before, ErlrouteNodes),
    {reply, ok, State#erlroute_state{monitors = may_establish_monitor(FlowDest, Monitors)}};

handle_call({unsubscribe, Topic, FlowDest}, _From,
            #erlroute_state{erlroute_nodes = ErlRouteNodes, monitors = Monitors} = State) ->
    Before = delivery_descriptor(Topic),
    delete_local_subscriber(Topic, FlowDest),
    _ = propagate_local_change(Topic, Before, ErlRouteNodes),
    {reply, ok, State#erlroute_state{monitors = may_release_monitor(FlowDest, Monitors)}};

handle_call({unsubscribe_all, Dest}, _From,
            #erlroute_state{erlroute_nodes = ErlRouteNodes, monitors = Monitors} = State) ->
    unsubscribe_all(Dest, ErlRouteNodes),
    {reply, ok, State#erlroute_state{monitors = may_release_monitor({process, Dest, info}, Monitors)}};

handle_call(Msg, _From, State) ->
    error_logger:warning_msg("we are in undefined handle_call with message ~p\n", [Msg]),
    {reply, ok, State}.

%--------------handle_cast-----------------

-spec handle_cast(Message, State) -> {noreply, erlroute_state()} | {stop, normal, erlroute_state()} when
    Message :: stop | term(),
    State   :: erlroute_state().

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle_cast with message ~p\n", [Msg]),
    {noreply, State}.

%--------------handle_info-----------------

-spec handle_info(Message, State) -> {noreply, erlroute_state()} | {stop, term(), erlroute_state()} when
    Message :: term(),
    State   :: erlroute_state().

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
        true  -> {noreply, State};
        false ->
            _ = announce_to(Node),
            {noreply, State#erlroute_state{erlroute_nodes = [Node | Nodes]}}
    end;

handle_info({erlroute_sync, Node, _Descriptors}, State) when Node =:= node() ->
    {noreply, State};
handle_info({erlroute_sync, Node, Descriptors}, #erlroute_state{erlroute_nodes = Nodes} = State) ->
    _ = apply_remote_descriptors(Node, Descriptors),
    case lists:member(Node, Nodes) of
        true  -> {noreply, State};
        false ->
            _ = announce_to(Node),
            {noreply, State#erlroute_state{erlroute_nodes = [Node | Nodes]}}
    end;

handle_info({set_remote_route, Topic, Descriptor, Node}, State) ->
    _ = upsert_remote_route(Topic, Node, Descriptor),
    {noreply, State};

handle_info({remove_remote_route, Topic, Node}, State) ->
    _ = remove_remote_routes(Topic, Node),
    {noreply, State};

handle_info({'DOWN', _Ref, process, Pid, _Reason},
            #erlroute_state{monitors = Monitors, erlroute_nodes = ErlRouteNodes} = State) ->
    _ = unsubscribe_local_pid(Pid, ErlRouteNodes),
    {noreply, State#erlroute_state{monitors = maps:remove(Pid, Monitors)}};

handle_info({'EXIT', Pid, Reason}, State) ->
    case lists:member(Pid, router_pids()) of
        true  -> {stop, {router_died, Pid, Reason}, State};
        false -> {noreply, State}
    end;

handle_info(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle_info with message ~p\n", [Msg]),
    {noreply, State}.

-spec terminate(Reason, State) -> ok when
    Reason  :: term(),
    State   :: erlroute_state().

terminate(_Reason, _State) ->
    _ = stop_routers(router_pids()),
    ok.

-spec router_pids() -> [pid()].

router_pids() ->
    try ets:lookup_element(?ROUTERETS, '$routers', 2) of
        Routers -> tuple_to_list(Routers)
    catch
        error:badarg -> []
    end.

-spec stop_routers(Routers :: [pid()]) -> ok.

stop_routers(Routers) ->
    lists:foreach(fun(Pid) ->
        unlink(Pid),
        MRef = erlang:monitor(process, Pid),
        exit(Pid, kill),
        receive {'DOWN', MRef, process, Pid, _} -> ok after 1000 -> ok end
    end, Routers).

-spec code_change(OldVsn, State, Extra) -> {ok, erlroute_state()} when
    OldVsn  :: term(),
    State   :: erlroute_state(),
    Extra   :: term().

code_change(_OldVsn, State, _Extra) -> {ok, State}.

% ============================= end of gen_server part =========================
% ----------------------------------- pub part ---------------------------------

-spec pub(Topic, Payload) -> pub_result() when Topic :: topic(), Payload :: payload().

pub(Topic, Payload) ->
    do_pub(Topic, Payload, all, sync).

-spec pub(Topic, Payload, PubType) -> pub_result() when
    Topic   :: topic(),
    Payload :: payload(),
    PubType :: pub_type().

pub(Topic, Payload, async) ->
    spawn(fun() -> do_pub(Topic, Payload, all, async) end),
    [];

pub(Topic, Payload, sync) ->
    do_pub(Topic, Payload, all, sync).

-spec pub_local(Topic, Payload) -> pub_result() when
    Topic   :: topic(),
    Payload :: payload().

pub_local(Topic, Payload) ->
    do_pub(Topic, Payload, local, sync).

-spec do_pub(topic(), payload(), scope(), pub_type()) -> pub_result().

do_pub(Topic, Payload, Scope, PubType) ->
    LocalSubs = case ets:lookup(?SUBETS, Topic) of
        [{Topic, Subs}] -> Subs;
        []              -> []
    end,
    R1 = deliver(LocalSubs, Payload, Topic, []),
    R2 = case Scope of
        local -> [];
        all   -> deliver_remote(ets:lookup(?REMOTETS, Topic), Payload, Topic, PubType, [])
    end,
    R1 ++ R2.

-spec deliver(Subs, Payload, Topic, Acc) -> pub_result() when
    Subs    :: [sub_spec()],
    Payload :: payload(),
    Topic   :: topic(),
    Acc     :: pub_result().

deliver([], _Payload, _Topic, Acc) ->
    Acc;

deliver([{process, Dest, info} | T], Payload, Topic, Acc) ->
    Dest ! Payload,
    deliver(T, Payload, Topic, [{Dest, info} | Acc]);

deliver([{process, Dest, cast} | T], Payload, Topic, Acc) ->
    gen_server:cast(Dest, Payload),
    deliver(T, Payload, Topic, [{Dest, cast} | Acc]);

deliver([{process, Dest, call} | T], Payload, Topic, Acc) ->
    try gen_server:call(Dest, Payload)
    catch Error:Reason ->
        error_logger:error_msg(
            "failed to dispatch ~p via gen_server:call to ~p for topic ~p: ~p:~p",
            [Payload, Dest, Topic, Error, Reason])
    end,
    deliver(T, Payload, Topic, [{Dest, call} | Acc]);

deliver([{function, {Function, ShallIncludeTopic} = Dest, Method} | T], Payload, Topic, Acc) ->
    try
        case Method of
            cast ->
                case {is_function(Function), ShallIncludeTopic} of
                    {true,  true}  -> spawn(fun() -> erlang:apply(Function, [Topic, Payload]) end);
                    {true,  false} -> spawn(fun() -> erlang:apply(Function, [Payload]) end);
                    {false, true}  -> {M,F,A} = Function, spawn(M, F, [Topic, Payload | A]);
                    {false, false} -> {M,F,A} = Function, spawn(M, F, [Payload | A])
                end;
            call ->
                case {is_function(Function), ShallIncludeTopic} of
                    {true,  true}  -> erlang:apply(Function, [Topic, Payload]);
                    {true,  false} -> erlang:apply(Function, [Payload]);
                    {false, true}  -> {M,F,A} = Function, apply(M, F, [Topic, Payload | A]);
                    {false, false} -> {M,F,A} = Function, apply(M, F, [Payload | A])
                end;
            {Node, cast} when is_atom(Node) ->
                case ShallIncludeTopic of
                    true  -> erpc:cast(Node, fun() -> erlang:apply(Function, [Topic, Payload]) end);
                    false -> erpc:cast(Node, fun() -> erlang:apply(Function, [Payload]) end)
                end;
            {Node, call} when is_atom(Node) ->
                case {is_function(Function), ShallIncludeTopic} of
                    {true,  true}  ->
                        erpc:call(Node, fun() -> erlang:apply(Function, [Topic, Payload]) end,
                                  ?DEFAULT_TIMEOUT_FOR_RPC);
                    {true,  false} ->
                        erpc:call(Node, fun() -> erlang:apply(Function, [Payload]) end,
                                  ?DEFAULT_TIMEOUT_FOR_RPC);
                    {false, true}  ->
                        {M,F,A} = Function,
                        erpc:call(Node, M, F, [Topic, Payload | A], ?DEFAULT_TIMEOUT_FOR_RPC);
                    {false, false} ->
                        {M,F,A} = Function,
                        erpc:call(Node, M, F, [Payload | A], ?DEFAULT_TIMEOUT_FOR_RPC)
                end
        end
    catch Error:Reason ->
        error_logger:error_msg(
            "failed to dispatch ~p via function ~p for topic ~p: ~p:~p",
            [Payload, Function, Topic, Error, Reason])
    end,
    deliver(T, Payload, Topic, [{Dest, Method} | Acc]).

-spec deliver_remote(RemoteSubs, Payload, Topic, PubType, Acc) -> pub_result() when
    RemoteSubs  :: [#remote_sub{}],
    Payload     :: payload(),
    Topic       :: topic(),
    PubType     :: pub_type(),
    Acc         :: pub_result().

deliver_remote([], _Payload, _Topic, _PubType, Acc) ->
    Acc;

deliver_remote([#remote_sub{dest_type = erlroute_on_other_node,
                            dest      = {_Node, RouterPid} = Dest,
                            method    = Method} | T],
               Payload, Topic, PubType, Acc) ->
    erlang:send(RouterPid, {remote_pub, PubType, Topic, Payload}),
    deliver_remote(T, Payload, Topic, PubType, [{Dest, Method} | Acc]);

deliver_remote([#remote_sub{dest_type = process_on_other_node,
                            dest      = {_Node, Proc} = Dest,
                            method    = info} | T],
               Payload, Topic, PubType, Acc) when is_pid(Proc) ->
    erlang:send(Proc, Payload),
    deliver_remote(T, Payload, Topic, PubType, [{Dest, info} | Acc]);

deliver_remote([#remote_sub{dest_type = process_on_other_node,
                            dest      = {Node, Proc} = Dest,
                            method    = info} | T],
               Payload, Topic, PubType, Acc) when is_atom(Proc) ->
    erlang:send({Proc, Node}, Payload),
    deliver_remote(T, Payload, Topic, PubType, [{Dest, info} | Acc]);

deliver_remote([#remote_sub{dest_type = process_on_other_node,
                            dest      = {_Node, Proc} = Dest,
                            method    = cast} | T],
               Payload, Topic, PubType, Acc) when is_pid(Proc) ->
    erlang:send(Proc, {'$gen_cast', Payload}),
    deliver_remote(T, Payload, Topic, PubType, [{Dest, cast} | Acc]);

deliver_remote([#remote_sub{dest_type = process_on_other_node,
                            dest      = {Node, Proc} = Dest,
                            method    = cast} | T],
               Payload, Topic, PubType, Acc) when is_atom(Proc) ->
    erlang:send({Proc, Node}, {'$gen_cast', Payload}),
    deliver_remote(T, Payload, Topic, PubType, [{Dest, cast} | Acc]);

deliver_remote([#remote_sub{dest_type = process_on_other_node,
                            dest      = {_Node, Proc} = Dest,
                            method    = call} | T],
               Payload, Topic, PubType, Acc) when is_pid(Proc) ->
    catch gen_server:call(Proc, Payload),
    deliver_remote(T, Payload, Topic, PubType, [{Dest, call} | Acc]);

deliver_remote([#remote_sub{dest_type = process_on_other_node,
                            dest      = {Node, Proc} = Dest,
                            method    = call} | T],
               Payload, Topic, PubType, Acc) when is_atom(Proc) ->
    catch gen_server:call({Proc, Node}, Payload),
    deliver_remote(T, Payload, Topic, PubType, [{Dest, call} | Acc]).

% ================================ end of pub part =============================
% ----------------------------------- sub part ---------------------------------

-spec sub(Target) -> ok when
    Target :: topic().

sub(Topic) when is_binary(Topic) ->
    sub(Topic, {process, self(), info}).

-spec sub(Topic, FlowDest) -> ok when
    Topic    :: topic(),
    FlowDest :: flow_dest() | pid() | atom() | fun() | {node(), fun()} | static_function() | {node(), static_function()}.

sub(Topic, {DestType, Dest, Method}) when
        is_binary(Topic),
        DestType =:= process orelse DestType =:= function ->
    gen_server:call(?MODULE, {subscribe, Topic, {DestType, Dest, Method}});

sub(Topic, FlowDest) when is_binary(Topic), (is_pid(FlowDest) orelse is_atom(FlowDest)) ->
    sub(Topic, {process, FlowDest, info});

sub(Topic, FlowDest) when is_binary(Topic), (is_function(FlowDest, 1) orelse is_function(FlowDest, 2)) ->
    sub(Topic, {function, {FlowDest, is_function(FlowDest, 2)}, cast});

sub(Topic, {Node, Function}) when is_binary(Topic), is_atom(Node),
        (is_function(Function, 1) orelse is_function(Function, 2)) ->
    sub(Topic, {function, {Function, is_function(Function, 2)}, {Node, cast}});

sub(Topic, {Module, Function, Arguments} = MFA) when is_binary(Topic),
        is_atom(Module), is_atom(Function), is_list(Arguments) ->
    sub(Topic, {function, gen_static_fun_dest('$local', MFA), cast});

sub(Topic, {Node, {Module, Function, Arguments} = MFA}) when is_binary(Topic),
        is_atom(Node), is_atom(Module), is_atom(Function), is_list(Arguments) ->
    sub(Topic, {function, gen_static_fun_dest(Node, MFA), {Node, cast}}).

-spec subscribe(Topic, FlowDest) -> ok when
    Topic    :: topic(),
    FlowDest :: flow_dest().

subscribe(Topic, {DestType, Dest, Method}) ->
    SubSpec = {DestType, Dest, Method},
    Current = case ets:lookup(?SUBETS, Topic) of
        [{Topic, Subs}] -> Subs;
        []              -> []
    end,
    case lists:member(SubSpec, Current) of
        false ->
            _ = ets:insert(?SUBETS, {Topic, [SubSpec | Current]}),
            maybe_index_pid(DestType, Dest, Topic);
        true  -> ok
    end.

-spec maybe_index_pid(dest_type(), dest(), topic()) -> ok.

maybe_index_pid(process, Pid, Topic) when is_pid(Pid) ->
    _ = ets:insert(?PIDETS, {Pid, Topic}),  % bag; identical tuple silently dropped
    ok;
maybe_index_pid(_, _, _) -> ok.

% ================================ end of sub part =============================
% ---------------------------------- unsub part --------------------------------

-spec unsub(Target) -> ok when
    Target :: 'all' | topic().

% @doc bulk unsubscribe: remove the calling process (by pid and registered name) from every topic
unsub(all) ->
    unsub(all, self()),
    case erlang:process_info(self(), registered_name) of
        {registered_name, Name} -> unsub(all, Name);
        []                      -> ok
    end;

unsub(Topic) when is_binary(Topic) ->
    unsub(Topic, {process, self(), info}),
    case erlang:process_info(self(), registered_name) of
        {registered_name, Name} -> unsub(Topic, {process, Name, info});
        []                      -> ok
    end.

-spec unsub(Topic, FlowDest) -> ok when
    Topic    :: 'all' | topic(),
    FlowDest :: flow_dest() | pid() | atom() | fun() | {node(), fun()} | static_function() | {node(), static_function()}.

% @doc bulk unsubscribe: remove a process destination (pid or registered name) from every topic
unsub(all, Dest) when is_pid(Dest) orelse is_atom(Dest) ->
    gen_server:call(?MODULE, {unsubscribe_all, Dest});

unsub(Topic, {DestType, Dest, Method}) when
        is_binary(Topic),
        DestType =:= process orelse DestType =:= function ->
    gen_server:call(?MODULE, {unsubscribe, Topic, {DestType, Dest, Method}});

unsub(Topic, FlowDest) when is_binary(Topic), (is_pid(FlowDest) orelse is_atom(FlowDest)) ->
    unsub(Topic, {process, FlowDest, info});

unsub(Topic, FlowDest) when is_binary(Topic), (is_function(FlowDest, 1) orelse is_function(FlowDest, 2)) ->
    unsub(Topic, {function, {FlowDest, is_function(FlowDest, 2)}, cast});

unsub(Topic, {Node, Function}) when is_binary(Topic), is_atom(Node),
        (is_function(Function, 1) orelse is_function(Function, 2)) ->
    unsub(Topic, {function, {Function, is_function(Function, 2)}, {Node, cast}});

unsub(Topic, {Module, Function, Arguments} = MFA) when is_binary(Topic),
        is_atom(Module), is_atom(Function), is_list(Arguments) ->
    unsub(Topic, {function, gen_static_fun_dest('$local', MFA), cast});

unsub(Topic, {Node, {Module, Function, Arguments} = MFA}) when is_binary(Topic),
        is_atom(Node), is_atom(Module), is_atom(Function), is_list(Arguments) ->
    unsub(Topic, {function, gen_static_fun_dest(Node, MFA), {Node, cast}}).

-spec delete_local_subscriber(Topic, FlowDest) -> ok when
    Topic    :: topic(),
    FlowDest :: flow_dest().

delete_local_subscriber(Topic, {DestType, Dest, Method}) ->
    SubSpec = {DestType, Dest, Method},
    case ets:lookup(?SUBETS, Topic) of
        [{Topic, Subs}] ->
            NewSubs = lists:delete(SubSpec, Subs),
            case NewSubs of
                []  -> ets:delete(?SUBETS, Topic);
                _   -> _ = ets:insert(?SUBETS, {Topic, NewSubs})
            end,
            maybe_unindex_pid(DestType, Dest, Topic, NewSubs);
        [] -> ok
    end.

-spec maybe_unindex_pid(dest_type(), dest(), topic(), [sub_spec()]) -> ok.

maybe_unindex_pid(process, Pid, Topic, RemainingSubs) when is_pid(Pid) ->
    case lists:any(fun({process, P, _}) -> P =:= Pid; (_) -> false end, RemainingSubs) of
        false -> _ = ets:delete_object(?PIDETS, {Pid, Topic}), ok;
        true  -> ok
    end;
maybe_unindex_pid(_, _, _, _) -> ok.

-spec delete_local_process(Pid) -> ok when Pid :: pid().

delete_local_process(Pid) ->
    Topics = [T || {_, T} <- ets:lookup(?PIDETS, Pid)],
    IsPidSub = fun({process, P, _}) -> P =:= Pid; (_) -> false end,
    lists:foreach(fun(Topic) ->
        case ets:lookup(?SUBETS, Topic) of
            [{Topic, Subs}] ->
                case [S || S <- Subs, not IsPidSub(S)] of
                    []      -> ets:delete(?SUBETS, Topic);
                    NewSubs -> _ = ets:insert(?SUBETS, {Topic, NewSubs})
                end;
            [] -> ok
        end
    end, Topics),
    _ = ets:delete(?PIDETS, Pid),
    ok.

-spec unsubscribe_local_pid(Pid, ErlRouteNodes) -> ok when
    Pid             :: pid(),
    ErlRouteNodes   :: [node()].

unsubscribe_local_pid(Pid, ErlRouteNodes) ->
    Affected = [T || {_, T} <- ets:lookup(?PIDETS, Pid)],
    Befores = [{T, delivery_descriptor(T)} || T <- Affected],
    delete_local_process(Pid),
    lists:foreach(fun({T, Before}) ->
        propagate_local_change(T, Before, ErlRouteNodes)
    end, Befores).

% Bulk unsubscribe a destination from every topic it appears on. A pid uses the
% ?PIDETS reverse index; a registered name is not indexed, so it falls back to a
% scan of ?SUBETS (only on explicit unsub(all, Name), never on the hot path).
-spec unsubscribe_all(Dest, ErlRouteNodes) -> ok when
    Dest          :: pid() | atom(),
    ErlRouteNodes :: [node()].

unsubscribe_all(Pid, ErlRouteNodes) when is_pid(Pid) ->
    unsubscribe_local_pid(Pid, ErlRouteNodes);
unsubscribe_all(Name, ErlRouteNodes) when is_atom(Name) ->
    IsNameSub = fun({process, D, _}) -> D =:= Name; (_) -> false end,
    Affected = [T || {T, Subs} <- ets:tab2list(?SUBETS), lists:any(IsNameSub, Subs)],
    Befores = [{T, delivery_descriptor(T)} || T <- Affected],
    lists:foreach(fun(T) -> delete_subs(T, IsNameSub) end, Affected),
    lists:foreach(fun({T, Before}) ->
        propagate_local_change(T, Before, ErlRouteNodes)
    end, Befores).

-spec delete_subs(Topic, Pred) -> ok when
    Topic :: topic(),
    Pred  :: fun((sub_spec()) -> boolean()).

delete_subs(Topic, Pred) ->
    case ets:lookup(?SUBETS, Topic) of
        [{Topic, Subs}] ->
            case [S || S <- Subs, not Pred(S)] of
                []      -> ets:delete(?SUBETS, Topic);
                NewSubs -> _ = ets:insert(?SUBETS, {Topic, NewSubs})
            end,
            ok;
        [] -> ok
    end.

-spec remove_remote_routes(Topic, Node) -> ok when
    Topic :: topic(),
    Node  :: node().

remove_remote_routes(Topic, Node) ->
    ets:match_delete(?REMOTETS, #remote_sub{topic = Topic, node = Node, _ = '_'}),
    ok.

-spec upsert_remote_route(Topic, Node, Descriptor) -> ok when
    Topic      :: topic(),
    Node       :: node(),
    Descriptor :: delivery_descriptor().

upsert_remote_route(Topic, Node, Descriptor) ->
    {DestType, Dest, Method} = case Descriptor of
        {direct, Proc, M} -> {process_on_other_node, {Node, Proc}, M};
        {pool, RouterPid} -> {erlroute_on_other_node, {Node, RouterPid}, pub_type_based}
    end,
    Existing = ets:match_object(?REMOTETS, #remote_sub{topic = Topic, node = Node, _ = '_'}),
    case Existing of
        [#remote_sub{dest_type = DestType, dest = Dest, method = Method}] ->
            ok;
        _ ->
            ets:match_delete(?REMOTETS, #remote_sub{topic = Topic, node = Node, _ = '_'}),
            ets:insert(?REMOTETS, #remote_sub{
                topic     = Topic,
                node      = Node,
                dest_type = DestType,
                dest      = Dest,
                method    = Method
            })
    end,
    ok.

-spec unsubscribe_node(Node) -> ok when Node :: node().

unsubscribe_node(Node) ->
    ets:match_delete(?REMOTETS, #remote_sub{node = Node, _ = '_'}),
    ok.

% ================================ end of sub part =============================
% ---------------------------------other functions -----------------------------

-spec gen_static_fun_dest(Node, StaticFunction) -> fun_dest() when
    Node           :: '$local' | node(),
    StaticFunction :: static_function().

gen_static_fun_dest('$local', {Module, Function, PredefinedArgs} = MFA) ->
    ExtraArgsLength = length(PredefinedArgs),
    case erlang:function_exported(Module, Function, ExtraArgsLength + 2) of
        true  -> {MFA, true};
        false ->
            case erlang:function_exported(Module, Function, ExtraArgsLength + 1) of
                true  -> {MFA, false};
                false -> throw(unknown_function)
            end
    end;
gen_static_fun_dest(Node, MFA) ->
    try gen_static_fun_dest('$local', MFA)
    catch _:_ ->
        erpc:call(Node, ?MODULE, gen_static_fun_dest, ['$local', MFA], ?DEFAULT_TIMEOUT_FOR_RPC)
    end.

-spec broadcast_to_nodes(Nodes, Msg) -> ok when
    Nodes :: [node()],
    Msg   :: term().

broadcast_to_nodes(Nodes, Msg) ->
    lists:foreach(fun(Node) -> erlang:send({?MODULE, Node}, Msg) end, Nodes).

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
    Descriptors :: [{topic(), delivery_descriptor()}].

apply_remote_descriptors(Node, Descriptors) ->
    lists:foreach(fun({Topic, Descriptor}) ->
        case Descriptor of
            none -> remove_remote_routes(Topic, Node);
            _    -> upsert_remote_route(Topic, Node, Descriptor)
        end
    end, Descriptors).

-spec delivery_descriptor(Topic) -> delivery_descriptor() when Topic :: topic().

delivery_descriptor(Topic) ->
    case ets:lookup(?SUBETS, Topic) of
        []              -> none;
        [{Topic, Subs}] -> descriptor_from_subs(Subs, Topic)
    end.

-spec descriptor_from_subs(Subs, Topic) -> delivery_descriptor() when
    Subs  :: [sub_spec()],
    Topic :: topic().

descriptor_from_subs([], _Topic)                        -> none;
descriptor_from_subs([{process, Proc, Method}], _Topic) -> {direct, Proc, Method};
descriptor_from_subs(_MultipleOrMixed, Topic)           -> {pool, assign_router(Topic)}.

-spec local_descriptors() -> [{topic(), delivery_descriptor()}].

local_descriptors() ->
    lists:foldl(fun({Topic, Subs}, Acc) ->
        case descriptor_from_subs(Subs, Topic) of
            none -> Acc;
            Desc -> [{Topic, Desc} | Acc]
        end
    end, [], ets:tab2list(?SUBETS)).

-spec propagate_local_change(Topic, Before, ErlRouteNodes) -> ok when
    Topic           :: topic(),
    Before          :: delivery_descriptor(),
    ErlRouteNodes   :: [node()].

propagate_local_change(Topic, Before, ErlRouteNodes) ->
    After = delivery_descriptor(Topic),
    maybe_propagate_descriptor(Before, After, Topic, ErlRouteNodes).

-spec maybe_propagate_descriptor(Before, After, Topic, ErlRouteNodes) -> ok when
    Before        :: delivery_descriptor(),
    After         :: delivery_descriptor(),
    Topic         :: topic(),
    ErlRouteNodes :: [node()].

maybe_propagate_descriptor(Same, Same, _Topic, _Nodes) -> ok;
maybe_propagate_descriptor(_Before, none, Topic, Nodes) ->
    broadcast_to_nodes(Nodes, {remove_remote_route, Topic, node()});
maybe_propagate_descriptor(_Before, After, Topic, Nodes) ->
    broadcast_to_nodes(Nodes, {set_remote_route, Topic, After, node()}).

% ------------------------------- router pool ---------------------------------

-spec router_pool_size() -> pos_integer().

router_pool_size() ->
    erlang:max(1, application:get_env(erlroute, router_pool_size, ?DEFAULT_ROUTER_POOL_SIZE)).

-spec assign_router(Topic) -> pid() when Topic :: topic().

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
                false -> ets:lookup_element(?ROUTERETS, Topic, 2)
            end
    end.

-spec may_establish_monitor(Dest, Monitors) -> #{pid() => reference()} when
    Dest     :: flow_dest(),
    Monitors :: #{pid() => reference()}.

may_establish_monitor({process, Proc, _Method}, Monitors) when is_pid(Proc) ->
    case maps:is_key(Proc, Monitors) of
        true  -> Monitors;
        false -> maps:put(Proc, erlang:monitor(process, Proc), Monitors)
    end;
may_establish_monitor(_NotMatch, Monitors) -> Monitors.

-spec may_release_monitor(FlowDest, Monitors) -> #{pid() => reference()} when
    FlowDest :: flow_dest(),
    Monitors :: #{pid() => reference()}.

may_release_monitor({process, Proc, _Method}, Monitors) when is_pid(Proc) ->
    case ets:lookup(?PIDETS, Proc) of
        [_ | _] -> Monitors;
        [] ->
            case maps:take(Proc, Monitors) of
                {Ref, NewMonitors} -> erlang:demonitor(Ref, [flush]), NewMonitors;
                error              -> Monitors
            end
    end;
may_release_monitor(_FlowDest, Monitors) -> Monitors.
