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
        generate_complete_routing_name/1, % export support function for parse_transform
        post_hitcache_routine/8
    ]).

% we will use ?MODULE as servername
-define(SERVER, ?MODULE).

% ----------------------------- gen_server part --------------------------------

% @doc start api
-spec start_link() -> Result when
    Result :: {ok,Pid} | ignore | {error,Error},
    Pid :: pid(),
    Error :: {already_started,Pid} | term().

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

% @doc simplified stop api. Defaul is sync call gen_server:stop
-spec stop() -> ok.

stop() ->
    stop(sync).

% @doc async/sync stop
-spec stop(Type) -> ok when
    Type :: 'sync' | 'async'.

stop(sync) ->
    gen_server:stop(?SERVER);
stop(async) ->
    gen_server:cast(?SERVER, stop).

% @doc gen_server init. We going to create ETS tables for dynamic routing rules in init section
-spec init([]) -> {ok, undefined}.

init([]) ->
    _ = ets:new('$erlroute_topics', [
            bag,
            public, % public for support full sync pub
            {read_concurrency, true}, % todo: test does it affect performance for writes?
            {keypos, #topics.topic},
            named_table
        ]),
    _ = ets:new('$erlroute_global_sub', [
            bag,
            public, % public for support full sync pub,
            {read_concurrency, true}, % todo: test doesrt affect performance for writes?
            {keypos, #subscribers_by_topic_only.topic},
            named_table
        ]),

    {ok, undefined}.

%--------------handle_call-----------------

% @doc callbacks for gen_server handle_call.
-spec handle_call(Message, From, State) -> Result when
    Message :: SubMsg | UnsubMsg,
    SubMsg :: {'subscribe', flow_source(), flow_dest()},
    UnsubMsg :: {'unsubscribe', flow_source(), flow_dest()},
    From :: {pid(), Tag},
    Tag :: term(),
    State :: term(),
    Result :: {reply, Result, State}.

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

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle_cast with message ~p\n",[Msg]),
    {noreply, State}.

%-----------end of handle_cast-------------

%--------------handle_info-----------------

% @doc callbacks for gen_server handle_info.
-spec handle_info(Message, State) -> Result when
    Message :: term(),
    State   :: term(),
    Result  :: {noreply, State}.

% @doc case for unknown messages
handle_info(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle_info with message ~p\n",[Msg]),
    {noreply, State}.

%-----------end of handle_info-------------

-spec terminate(Reason, State) -> term() when
    Reason :: 'normal' | 'shutdown' | {'shutdown',term()} | term(),
    State :: term().

terminate(Reason, State) ->
    {noreply, Reason, State}.

-spec code_change(OldVsn, State, Extra) -> Result when
    OldVsn :: Vsn | {down, Vsn},
    Vsn :: term(),
    State :: term(),
    Extra :: term(),
    Result :: {ok, NewState},
    NewState :: term().

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% ============================= end of gen_server part =========================
% ----------------------------------- pub part ---------------------------------

% @doc Publish message API. Default is hybrid behaviour:
% - check if route table existing (cache per module)
% - for cached routes it send message async
% - at the end it cast to erlroute and erlroute try to match not yet cached routes
%
% Also aviable 'erlroute:full_async_pub/5' and 'erlroute:full_sync_pub/5' with same parameters.
%
% For publish avialiable following parse_transform and macros shourtcuts:
%
% pub(Message) ----> generating topic and transforming to
% pub(?MODULE, self(), ?LINE, <<"?MODULE.?LINE">>, Message, hybrid, '$erlroute_?MODULE')
%
% pub(Message, Topic) ----> transforming to
% pub(?MODULE, self(), ?LINE, Topic, Message, hybrid, '$erlroute_?MODULE')
%
% To use parse transform +{parse_transform, erlroute_transform} must be added as compile options.
%
% Return: return depends on what kind of behaviour has choosen.
% - for hybrid it return list of process where erlroute send message matched from cache. It doesn't include post-matching.
% - for async it always return empty list.
% - for sync it return full list of destination processes where erlroute actually send message.


% shortcut (should use parse transform better than pub/1)
-spec pub(Message) -> Result when
    Message ::  term(),
    Result  ::  pubresult().

pub(Message) ->
    Module = ?MODULE,
    Line = ?LINE,
    Topic = list_to_binary(lists:concat([Module,",",Line])),
    error_logger:warning_msg("Attempt to use pub/1 without parse_transform. ?MODULE, ?LINE and Topic will be wrong."),
    pub(Module, self(), Line, Topic, Message, 'hybrid', generate_complete_routing_name(Module)).

% shortcut (should use parse transform better than pub/2)
-spec pub(Topic, Message) -> Result when
    Message ::  term(),
    Topic   ::  binary(),
    Result  ::  pubresult().

pub(Topic, Message) ->
    Module = ?MODULE,
    Line = ?LINE,
    error_logger:warning_msg("Attempt to use pub/2 without parse_transform. ?MODULE and ?LINE will be wrong."),
    pub(Module, self(), Line, Topic, Message, 'hybrid', generate_complete_routing_name(Module)).

% hybrid
-spec pub(Module, Process, Line, Topic, Message) -> Result when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  binary(),
    Message ::  term(),
    Result  ::  pubresult().

pub(Module, Process, Line, Topic, Message) ->
    error_logger:warning_msg("Attempt to use pub/5 without parse_transform."),
    pub(Module, Process, Line, Topic, Message, 'hybrid', generate_complete_routing_name(Module)).

% full_async
-spec full_async_pub(Module, Process, Line, Topic, Message) -> Result when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  binary(),
    Message ::  term(),
    Result  ::  []. % in async we always return [] cuz we don't know yet subscribers

full_async_pub(Module, Process, Line, Topic, Message) ->
    pub(Module, Process, Line, Topic, Message, async, generate_complete_routing_name(Module)).

% full_sync
-spec full_sync_pub(Module, Process, Line, Topic, Message) -> Result when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  binary(),
    Message ::  term(),
    Result  ::  pubresult().

full_sync_pub(Module, Process, Line, Topic, Message) ->
    pub(Module, Process, Line, Topic, Message, sync, generate_complete_routing_name(Module)).

% @doc full parameter pub
-spec pub(Module, Process, Line, Topic, Message, PubType, EtsName) -> Result when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  binary(),
    Message ::  term(),
    PubType ::  pubtype(),
    EtsName ::  atom(),
    Result  ::  pubresult().

pub(Module, Process, Line, Topic, Message, hybrid, EtsName) ->
    WhoGetWhileSync = load_routing_and_send(EtsName, Topic, Message, []),
    PostRef = gen_id(),
    spawn(?MODULE, post_hitcache_routine, [Module, Process, Line, Topic, Message, EtsName, WhoGetWhileSync, PostRef]),
    WhoGetWhileSync;

pub(Module, Process, Line, Topic, Message, async, EtsName) ->
    spawn(?MODULE, pub, [Module, Process, Line, Topic, Message, sync, EtsName]),
    [];

pub(Module, Process, Line, Topic, Message, sync, EtsName) ->
    WhoGetWhileSync = load_routing_and_send(EtsName, Topic, Message, []),
    post_hitcache_routine(Module, Process, Line, Topic, Message, EtsName, WhoGetWhileSync, undefined).

% load routing recursion
load_routing_and_send(EtsName, Topic, Message, Acc) ->
    try ets:lookup(EtsName, Topic) of
        [] when Topic =/= <<"*">> ->
            load_routing_and_send(EtsName, <<"*">>, Message, Acc);
        [] ->
            Acc;
        Routes when Topic =/= <<"*">> ->
            % send to wildcard-topic subscribers
            load_routing_and_send(EtsName, <<"*">>, Message, send(Routes, Message, Topic, Acc));
        Routes ->
            send(Routes, Message, Topic, Acc)
    catch
        _:_ ->
            Acc
    end.

-spec send(Routes, Message, Topic, Acc) -> Result when
    Routes  ::  [complete_routes()],
    Message ::  term(),
    Topic   ::  topic(),
    Acc     ::  [proc()],
    Result  ::  [proc()].

% sending to standart process
send([#complete_routes{dest_type = 'process', dest = Process, method = Method}|T], Message, Topic, Acc) ->
    case Method of
        info -> Process ! Message;
        cast -> gen_server:cast(Process, Message);
        call -> gen_server:call(Process, Message)
    end,
    send(T, Message, Topic, [Process|Acc]);

% fun apply
send([#complete_routes{dest_type = 'function', dest = Function, method = apply}|T], Message, Topic, Acc) when is_function(Function, 1) ->
    send(T, Message, Topic, [spawn(fun() -> erlang:apply(Function, [Message]) end) | Acc]);
send([#complete_routes{dest_type = 'function', dest = Function, method = apply}|T], Message, Topic, Acc) when is_function(Function, 2) ->
    send(T, Message, Topic, [spawn(fun() -> erlang:apply(Function, [Topic, Message]) end) | Acc]);


% sending to poolboy pool
send([#complete_routes{dest_type = 'poolboy', dest = PoolName, method = Method}|T], Message, Topic, Acc) ->
    NewAcc = try poolboy:checkout(PoolName) of
        Worker when is_pid(Worker) ->
            case Method of
                info -> Worker ! Message;
                cast -> gen_server:cast(Worker, Message);
                call -> gen_server:call(Worker, Message)
            end,
            poolboy:checkin(PoolName, Worker),
            [Worker|Acc];
        _ ->
            error_logger:error_msg("Worker not is pid"),
            Acc
    catch
        X:Y -> error_logger:error_msg("Looks like poolboy pool ~p not found, got error ~p with reason ~p",[PoolName,X,Y]), Acc
    end,
    send(T, Message, Topic, NewAcc);

% final clause for empty list
send([], _Message, _Topic, Acc) -> Acc.

% ================================ end of pub part =============================
% ----------------------------------- sub part ---------------------------------

% @doc Subscribe API to the message flow.
% Erlroute suport pid, registered process name and the message pool like https://github.com/devinus/poolboy[Poolboy^] as destination.
% For the process subscribed by pid or registered name it just send message.
% For the pools for every new message it checkout one worker, then send message to that worker and then checkin.

-spec sub(Target) -> ok when
    Target  :: flow_source() | nonempty_list() | binary() | module().

% @doc subscribe current process to all messages from module Module
sub(Module) when is_atom(Module) -> sub(#flow_source{module = Module, topic = <<"*">>}, {process, self(), info});
% @doc subscribe current process to messages with topic Topic from any module
sub(Topic) when is_binary(Topic) -> sub(#flow_source{module = undefined, topic = Topic}, {process, self(), info});
% @doc subscribe current process to messages with full-defined FlowSource ([{module, Module}, {topic, Topic}])
sub(FlowSource) when is_list(FlowSource) -> sub(FlowSource, {process, self(), info}).

% @doc full subscribtion api
-spec sub(FlowSource,FlowDest) -> ok when
    FlowSource  :: flow_source() | nonempty_list() | binary() | module(),
    FlowDest    :: flow_dest() | pid() | atom() | fun().

sub(FlowSource = #flow_source{module = Module, topic = Topic}, {DestType, Dest, Method}) when
        is_atom(Module),
        is_binary(Topic),
        DestType =:= 'process' orelse DestType =:= 'poolboy' orelse DestType =:= 'function',
        is_pid(Dest) orelse is_atom(Dest) orelse is_function(Dest),
        Method =:= 'info' orelse Method =:= 'cast' orelse Method =:= 'call' orelse Method =:= 'apply' ->
    gen_server:call(?MODULE, {subscribe, FlowSource, {DestType, Dest, Method}});

sub(FlowSource, FlowDest) when is_function(FlowDest, 1) orelse is_function(FlowDest, 2) ->
    sub(FlowSource, {function, FlowDest, apply});

% when Dest is pid() or atom
sub(FlowSource, FlowDest) when is_pid(FlowDest) orelse is_atom(FlowDest) ->
    sub(FlowSource, {process, FlowDest, info});

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

unsubscribe(_FlowSource,_FlowDest) -> ok. % todo
% ================================ end of sub part =============================




% ---------------------------------other functions -----------------------------

post_hitcache_routine(Module, Process, Line, Topic, Message, EtsName, WhoGetAlready, PostRef) ->
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
            case (PostRef =:= undefined orelse SubRef < PostRef) andalso lists:member(Dest, WhoGetAlready) of
                false ->
                    ToInsert = #complete_routes{
                        topic = Topic,
                        dest_type = DestType,
                        dest = Dest,
                        method = Method,
                        parent_topic = {'$erlroute_global_sub', Topic}
                    },
                    Toreturn = send([ToInsert], Message, Topic, []),
                    ets:insert(route_table_must_present(EtsName), ToInsert),
                    Toreturn;
                true ->
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

% @doc Generate unique id
-spec gen_id() -> Result when
    Result      :: integer().

gen_id() -> erlang:unique_integer([monotonic]).

% @doc split binary topic to the list
% binary:split/2 doesn't work well if contain pattern like .*
-spec split_topic(Key) -> Result when
    Key :: binary(),
    Result :: nonempty_list().

split_topic(Bin) ->
    split_topic(Bin, [], []).
split_topic(<<>>, WAcc, Result) ->
    lists:reverse([lists:reverse(WAcc)|Result]);
split_topic(<<2#00101110:8, Rest/binary>>, WAcc, Result) ->
    split_topic(Rest, [], [lists:reverse(WAcc)|Result]);
split_topic(<<Char:8, Rest/binary>>, WAcc, Result) ->
    split_topic(Rest, [Char|WAcc], Result);
split_topic(<<>>, [], []) -> [].
