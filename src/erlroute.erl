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

-define(DEFAULT_TIMEOUT_FOR_RPC, 10000).
-define(SERVER, ?MODULE).

-include("erlroute.hrl").
-include_lib("kernel/include/logger.hrl").

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
        generate_complete_routing_name/1, % export support function for parse_transform
        post_hitcache_routine/8,
		gen_static_fun_dest/2
    ]).

% ----------------------------- gen_server part --------------------------------

% @doc start api
-spec start_link() -> Result when
    Result      :: {ok,Pid} | ignore | {error,Error},
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
    TopicsTid = ets:new('$erlroute_topics', [
            bag,
            public, % public for support full sync pub
            {read_concurrency, true}, % todo: test does it affect performance for writes?
            {keypos, #topics.topic},
            named_table
        ]),
    GlobalSubTid = ets:new('$erlroute_global_sub', [
            bag,
            public, % public for support full sync pub,
            {read_concurrency, true}, % todo: test doesrt affect performance for writes?
            {keypos, #subscribers_by_topic_only.topic},
            named_table
        ]),
    _ = net_kernel:monitor_nodes(true),
    Nodes = discover_erlroute_nodes(),
    {ok, #erlroute_state{erlroute_topics_ets = TopicsTid, erlroute_global_sub_ets = GlobalSubTid, erlroute_nodes = Nodes}}.

%--------------handle_call-----------------

% @doc callbacks for gen_server handle_call.
-spec handle_call(Message, From, State) -> Result when
    Message     :: SubMsg | UnsubMsg,
    SubMsg      :: {'subscribe', flow_source(), flow_dest()},
    UnsubMsg    :: {'unsubscribe', flow_source(), flow_dest()},
    From        :: {pid(), Tag},
    Tag         :: term(),
    State       :: erlroute_state(),
    Result      :: {reply, term(), erlroute_state()}.

handle_call({subscribe, FlowSource, FlowDest}, _From, State) ->
    Result = subscribe(FlowSource, FlowDest),
    {reply, Result, State};

handle_call({unsubscribe, FlowSource, FlowDest}, _From, State) ->
    unsubscribe(FlowSource, FlowDest),
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
    Message     :: {nodeup, node()} | {nodedown, node()},
    State       :: erlroute_state(),
    Result      :: {noreply, erlroute_state()}.

% todo: populate to that node our subscribtions
handle_info({nodeup, Node}, #erlroute_state{erlroute_nodes = Nodes} = State) ->
    try erpc:call(Node, erlang, function_exported, [?MODULE, start_link], ?DEFAULT_TIMEOUT_FOR_RPC) of
        true ->
            {noreply, State#erlroute_state{erlroute_nodes = lists:uniq([Node | Nodes])}};
        false ->
            {noreply, State#erlroute_state{erlroute_nodes = Nodes -- [Node]}}
    catch
        _:_ ->
            {noreply, State}
    end;

% todo: unsubscribe that node after some timeout
handle_info({nodedown, Node}, #erlroute_state{erlroute_nodes = Nodes} = State) ->
    {noreply, State#erlroute_state{erlroute_nodes = Nodes -- [Node]}};

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
% pub(Payload, Topic) ----> transforming to
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
    pub(Module, self(), Line, Topic, Payload, 'hybrid', generate_complete_routing_name(Module)).

% shortcut (should use parse transform better than pub/2)
-spec pub(Topic, Payload) -> Result when
    Topic   ::  topic(),
    Payload ::  payload(),
    Result  ::  pub_result().

pub(Topic, Payload) ->
    Module = ?MODULE,
    Line = ?LINE,
    error_logger:warning_msg("Attempt to use pub/2 without parse_transform. ?MODULE and ?LINE will be wrong."),
    pub(Module, self(), Line, Topic, Payload, 'hybrid', generate_complete_routing_name(Module)).

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
    pub(Module, Process, Line, Topic, Payload, 'hybrid', generate_complete_routing_name(Module)).

% full_async
-spec full_async_pub(Module, Process, Line, Topic, Payload) -> Result when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  topic(),
    Payload ::  payload(),
    Result  ::  []. % in async we always return [] cuz we don't know yet subscribers

full_async_pub(Module, Process, Line, Topic, Payload) ->
    pub(Module, Process, Line, Topic, Payload, async, generate_complete_routing_name(Module)).

% full_sync
-spec full_sync_pub(Module, Process, Line, Topic, Payload) -> Result when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  topic(),
    Payload ::  payload(),
    Result  ::  pub_result().

full_sync_pub(Module, Process, Line, Topic, Payload) ->
    pub(Module, Process, Line, Topic, Payload, sync, generate_complete_routing_name(Module)).

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

pub(Module, Process, Line, Topic, Payload, hybrid, EtsName) ->
    WhoGetWhileSync = load_routing_and_send(ets:whereis(EtsName), Topic, Payload, []),
    PostRef = gen_id(),
    spawn(?MODULE, post_hitcache_routine, [Module, Process, Line, Topic, Payload, EtsName, WhoGetWhileSync, PostRef]),
    WhoGetWhileSync;

pub(Module, Process, Line, Topic, Payload, async, EtsName) ->
    spawn(?MODULE, pub, [Module, Process, Line, Topic, Payload, sync, EtsName]),
    [];

pub(Module, Process, Line, Topic, Payload, sync, EtsName) ->
    post_hitcache_routine(
        Module,
        Process,
        Line,
        Topic,
        Payload,
        EtsName,
        load_routing_and_send(ets:whereis(EtsName), Topic, Payload, []),
        undefined
    ).

-spec load_routing_and_send(EtsTidOrName, Topic, Payload, Acc) -> Result when
    EtsTidOrName  :: atom() | ets:tid(),
    Topic         :: topic(),
    Payload       :: payload(),
    Acc           :: pub_result(),
    Result        :: pub_result().

load_routing_and_send(undefined, _Topic, _Payload, Acc) -> Acc;
load_routing_and_send(EtsTid, Topic, Payload, Acc) ->
    try ets:lookup(EtsTid, Topic) of
        [] when Topic =/= <<"*">> ->
            load_routing_and_send(EtsTid, <<"*">>, Payload, Acc);
        [] ->
            Acc;
        Routes when Topic =/= <<"*">> ->
            % send to wildcard-topic subscribers
            load_routing_and_send(EtsTid, <<"*">>, Payload, send(Routes, Payload, Topic, Acc));
        Routes ->
            send(Routes, Payload, Topic, Acc)
    catch
        _:_ ->
            Acc
    end.

-spec send(Routes, Payload, Topic, Acc) -> Result when
    Routes  ::  [complete_routes()],
    Payload ::  payload(),
    Topic   ::  topic(),
    Acc     ::  pub_result(),
    Result  ::  pub_result().

% sending to standart process
send([#complete_routes{dest_type = 'process', method = Method, dest = Process}|T], Payload, Topic, Acc) ->
    case Method of
        info -> Process ! Payload;
        cast -> gen_server:cast(Process, Payload);
        call -> gen_server:call(Process, Payload)
    end,
    send(T, Payload, Topic, [{Process, Method} | Acc]);

% apply process
send([#complete_routes{dest_type = 'function', method = Method, dest = {Function, ShellIncludeTopic} = Dest}|T], Payload, Topic, Acc) ->
    case Method of
        cast ->
			case {is_function(Function), ShellIncludeTopic} of
                {true, true} ->
                    spawn(fun() -> erlang:apply(Function, [Topic, Payload]) end);
                {true, false} ->
                    spawn(fun() -> erlang:apply(Function, [Payload]) end);
                {false, true} ->
					{Module, StaticFunction, PredefinedArgs} = Function,
                    spawn(Module, StaticFunction, [Topic, Payload | PredefinedArgs]);
                {false, false} ->
					{Module, StaticFunction, PredefinedArgs} = Function,
                    spawn(Module, StaticFunction, [Payload | PredefinedArgs])
            end;
        call ->
			case {is_function(Function), ShellIncludeTopic} of
                {true, true} ->
                    erlang:apply(Function, [Topic, Payload]);
                {true, false} ->
                    erlang:apply(Function, [Payload]);
                {false, true} ->
                    {Module, StaticFunction, PredefinedArgs} = Function,
                    Module:StaticFunction([Topic, Payload | PredefinedArgs]);
				{false, false} ->
                    {Module, StaticFunction, PredefinedArgs} = Function,
                    Module:StaticFunction([Payload | PredefinedArgs])
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
                    {Module, StaticFunction, PredefinedArgs} = Function,
                    erpc:call(Node, Module, StaticFunction, [Topic, Payload | PredefinedArgs], ?DEFAULT_TIMEOUT_FOR_RPC);
				{false, false} ->
                    {Module, StaticFunction, PredefinedArgs} = Function,
                    erpc:call(Node, Module, StaticFunction, [Topic, Payload | PredefinedArgs], ?DEFAULT_TIMEOUT_FOR_RPC)
            end
    end,
    send(T, Payload, Topic, [{Dest, Method} | Acc]);

% sending to poolboy pool
send([#complete_routes{dest_type = 'poolboy', method = Method, dest = PoolName}|T], Payload, Topic, Acc) ->
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
    send(T, Payload, Topic, [{PoolName, Method} | Acc]);

% final clause for empty list
send([], _Payload, _Topic, Acc) -> Acc.

% ================================ end of pub part =============================
% ----------------------------------- sub part ---------------------------------

% @doc Subscribe API to the message flow.
% Erlroute suport pid, registered process name and the message pool like https://github.com/devinus/poolboy[Poolboy^] as destination.
% For the process subscribed by pid or registered name it just send message.
% For the pools for every new message it checkout one worker, then send message to that worker and then checkin.

-spec sub(Target) -> ok when
    Target  :: flow_source() | nonempty_list() | topic() | module().

% @doc subscribe current process to all messages from module Module
sub(Module) when is_atom(Module) -> sub(#flow_source{module = Module, topic = <<"*">>}, {process, self(), info});

% @doc subscribe current process to messages with topic Topic from any module
sub(Topic) when is_binary(Topic) -> sub(#flow_source{module = undefined, topic = Topic}, {process, self(), info});

% @doc subscribe current process to messages with full-defined FlowSource ([{module, Module}, {topic, Topic}])
sub(FlowSource) when is_list(FlowSource) -> sub(FlowSource, {process, self(), info}).

% @doc full subscribtion api
-spec sub(FlowSource, FlowDest) -> ok when
    FlowSource  :: flow_source() | nonempty_list() | topic() | module(),
    FlowDest    :: flow_dest()
                 | pid()
                 | atom()
                 | fun() | {node() | fun()}
                 | static_function() | {node(), static_function()}.

sub(FlowSource = #flow_source{module = Module, topic = Topic}, {DestType, Dest, Method}) when
        is_atom(Module),
        is_binary(Topic),
        DestType =:= 'process' orelse DestType =:= 'poolboy' orelse DestType =:= 'function'  ->
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
                false -> <<"*">>;
                {topic, Data} -> Data
            end
        }, FlowDest).


-spec subscribe(FlowSource,FlowDest) -> ok when
    FlowSource  ::  flow_source() | nonempty_list(),
    FlowDest    ::  flow_dest().

% @doc subscribe with undefined module
subscribe(#flow_source{module = undefined, topic = Topic}, {DestType, Dest, Method}) ->
    {IsFinal, Words} = is_final_topic(Topic),
    ets:insert('$erlroute_global_sub', #subscribers_by_topic_only{
        topic = Topic,
        is_final_topic = IsFinal,
        words = Words,
        dest_type = DestType,
        dest = Dest,
        method = Method,
        sub_ref = gen_id()
    }),
    _ = case IsFinal of
        true ->
            lists:map(fun(#topics{module = Module}) ->
                ets:insert(route_table_must_present(generate_complete_routing_name(Module)),
                    #complete_routes{
                        topic = Topic,
                        dest_type = DestType,
                        dest = Dest,
                        method = Method,
                        parent_topic = {'$erlroute_global_sub', Topic}
                    }
                )
            end, ets:lookup('$erlroute_topics',Topic));
        false -> todo % implement for parametrized topics
    end,
    ok;

% @doc subscribe for specified module
subscribe(#flow_source{module = Module, topic = Topic}, {DestType, Dest, Method}) ->
    {IsFinal, Words} = is_final_topic(Topic),
    case IsFinal of
        true ->
            EtsName = generate_complete_routing_name(Module),
            _ = route_table_must_present(EtsName),
            ets:insert(EtsName, #complete_routes{topic=Topic, dest_type=DestType, dest=Dest, method=Method});
        false ->
            EtsName = generate_parametrized_routing_name(Module),
            _ = route_table_must_present(EtsName),
            ets:insert(EtsName, #parametrize_routes{topic=Topic, dest_type=DestType, dest=Dest, method=Method, words=Words})
            % todo: then need try match this topic from '$erlroute_topics'
    end, ok.

% ================================ end of sub part =============================
% ----------------------------------- unsub part -------------------------------

% todo
-spec unsubscribe(FlowSource, FlowDest) -> Result when
    FlowSource  :: term(),
    FlowDest    :: term(),
    Result      :: term().
unsubscribe(_FlowSource,_FlowDest) -> ok.
% ================================ end of sub part =============================

% ---------------------------------other functions -----------------------------

-spec post_hitcache_routine(Module, Process, Line, Topic, Payload, EtsName, WhoGetAlready, PostRef) -> Result when
    Module          :: module(),
    Process         :: pid(),
    Line            :: pos_integer(),
    Topic           :: topic(),
    Payload         :: payload(),
    EtsName         :: atom(),
    WhoGetAlready   :: pub_result(),
    PostRef         :: undefined | reference(),
    Result          :: term(). % todo

post_hitcache_routine(Module, Process, Line, Topic, Payload, EtsName, WhoGetAlready, PostRef) ->
    Words = split_topic(Topic),
    ProcessToWrite = case is_pid(Process) of
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
    end,
    _ = ets:insert('$erlroute_topics', #topics{
        topic = Topic,
        words = Words,
        module = Module,
        line = Line,
        process = ProcessToWrite
    }),
    % match global subscribers with specified topic
    lists:append(WhoGetAlready, lists:map(
        % todo: maybe better use matchspec?
        fun(#subscribers_by_topic_only{dest_type = DestType, dest = Dest, method = Method, sub_ref = SubRef}) ->
            case lists:member({Dest, Method}, WhoGetAlready) of
                false when PostRef =:= undefined orelse PostRef > SubRef ->
                    ToInsert = #complete_routes{
                        topic = Topic,
                        dest_type = DestType,
                        dest = Dest,
                        method = Method,
                        parent_topic = {'$erlroute_global_sub', Topic}
                    },
                    Toreturn = send([ToInsert], Payload, Topic, []),
                    ets:insert(route_table_must_present(EtsName), ToInsert),
                    Toreturn;
                false when PostRef =/= undefined ->
                    error_logger:error_msg("Face race condition when Subscribe reference ~p is Lower than pub_ref ~p\n",[SubRef, PostRef]);
                _ ->
                    []
            end
        end, ets:lookup('$erlroute_global_sub', Topic)
    )).


% @doc generate ets name for Module for completed topics
-spec generate_complete_routing_name(Module) -> EtsName when
    Module  ::  module(),
    EtsName ::  atom().

generate_complete_routing_name(Module) when is_atom(Module)->
    list_to_atom("$erlroute_cmp_" ++ atom_to_list(Module)).

% @doc generate ets name for Module for parametrized topics
-spec generate_parametrized_routing_name(Module) -> EtsName when
    Module  ::  module(),
    EtsName ::  atom().

generate_parametrized_routing_name(Module) when is_atom(Module)->
    list_to_atom("$erlroute_prm_" ++ atom_to_list(Module)).

% @doc Check if ets routing table is present, on falure - let's create it
-spec route_table_must_present (EtsName) -> Result when
      EtsName   ::  atom(),
      Result    ::  atom().

route_table_must_present(EtsName) ->
    case ets:info(EtsName, size) of
        undefined ->
            case whereis(?SERVER) == self() of
                true ->
                    _Tid = ets:new(EtsName, [bag, public,
                        {read_concurrency, true},
                        {keypos, #complete_routes.topic},
                        named_table
                    ]), EtsName;
                false ->
                    gen_server:call(?SERVER, {regtable, EtsName})
            end;
       _ ->
           EtsName
   end.

% @doc check is this topic in final condition or not.
% if it contain * or ! it means this is parametrized topic
-spec is_final_topic(Topic) -> Result when
    Topic :: topic(),
    Result :: {boolean(), Words},
    Words :: 'undefined' | nonempty_list().

is_final_topic(<<"*">>) -> {true, undefined};
is_final_topic(Topic) ->
    case binary:match(Topic, [<<"*">>,<<"!">>]) of
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
	Node			:: '$local' | node(),
	StaticFunction	:: static_function(),
	Result			:: fun_dest().

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
			erpc:call(Node, ?MODULE, gen_static_fun_dest, ['$local', MFA], 1000)
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


