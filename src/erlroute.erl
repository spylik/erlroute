%% --------------------------------------------------------------------------------
%% File:    erlroute.erl
%% @author  Oleksii Semilietov <spylik@gmail.com>
%%
%% --------------------------------------------------------------------------------

-module(erlroute).
-define(NOTEST, true).
-ifdef(TEST).
    -compile(export_all).
-endif.

-include("erlroute.hrl").
-include("deps/teaser/include/utils.hrl").

% gen server is here
-behaviour(gen_server).

% gen_server api
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

% public api 
-export([
        start_link/0,
        stop/0, stop/1,
        pub/5,
        full_async_pub/5,
        full_sync_pub/5,
        sub/2,
        sub/1
    ]).

% we will use ?MODULE as servername
-define(SERVER, ?MODULE).

% ----------------------------- gen_server part --------------------------------

% star/stop api
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

stop() ->
    stop(sync).
stop(sync) ->
    gen_server:call(?SERVER, stop);
stop(async) ->
    gen_server:cast(?SERVER, stop).

% we going to create ETS tables for dynamic routing rules in init section
-spec init([]) -> {ok, undefined}.

init([]) ->
    _ = ets:new('$erlroute_topics', [
            bag,
            protected,
            {keypos, #topics.topic},
            named_table
        ]),
    {ok, undefined}.

%--------------handle_call-----------------

handle_call({subscribe, FlowSource, FlowDest}, _From, State) ->
    Result = subscribe(FlowSource, FlowDest),
    {reply, Result, State};

handle_call({unsubscribe, FlowSource, FlowDest}, _From, State) ->
    unsubscribe(FlowSource, FlowDest),
    {reply, ok, State};

handle_call(stop, _From, State) ->
    {stop, normal, State};

handle_call(Msg, _From, State) ->
    error_logger:warning_msg("we are in undefined handle_call with message ~p\n",[Msg]),
    {reply, ok, State}.

%-----------end of handle_call-------------

%--------------handle_cast-----------------

handle_cast({new_msg, Module, Process, Line, Topic, _Message, _EtsName, _WhoGetWhileSync}, State) ->
    TopicsKey = split_topic(Topic),
    ets:insert('$erlroute_topics', #topics{
            topic = Topic, 
            words = TopicsKey,
            module = Module,
            line = Line,
            process = Process
        }),
%    EtsSize = ets:info(EtsName, size),
%    case ets:info(EtsName, size) of
%        undefined -> ok;
%        _ ->
%            MS = [{#complete_routes{is_final_topic = false, _ = '_'},
%                    [], 
%                    ['$_']
%                }],
%            lists:map(
%                fun(#complete_routes{topic = Top, words = Words}) ->
%                    ?debug("Topic is ~p, Words is ~p",[Top, Words])
%                end, 
%                ets:select(EtsName, MS)
%            )
%    end,
    {noreply, State};

handle_cast({subscribe, FlowSource, FlowDest}, State) ->
    subscribe(FlowSource,FlowDest),
    {noreply, State};

handle_cast({unsubscribe, FlowSource, FlowDest}, State) ->
    unsubscribe(FlowSource,FlowDest),
    {noreply, State};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle_cast with message ~p\n",[Msg]),
    {noreply, State}.

%-----------end of handle_cast-------------

%--------------handle_info-----------------

handle_info(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle_info with message ~p\n",[Msg]),
    {noreply, State}.

%-----------end of handle_info-------------

terminate(Reason, State) ->
    {noreply, Reason, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% ============================= end of gen_server part =========================
% ----------------------------------- pub part ---------------------------------

% @doc Publish message. Default is hybrid behaviour:
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

% hybrid
-spec pub(Module, Process, Line, Topic, Message) -> ok when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  binary(),
    Message ::  term().

pub(Module, Process, Line, Topic, Message) ->
    pub(Module, Process, Line, Topic, Message, hybrid, generate_complete_routing_name(Module)).

% full_async
-spec full_async_pub(Module, Process, Line, Topic, Message) -> ok when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  binary(),
    Message ::  term().

full_async_pub(Module, Process, Line, Topic, Message) ->
    pub(Module, Process, Line, Topic, Message, async, generate_complete_routing_name(Module)).

% full_sync
-spec full_sync_pub(Module, Process, Line, Topic, Message) -> ok when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  binary(),
    Message ::  term().

full_sync_pub(Module, Process, Line, Topic, Message) ->
    pub(Module, Process, Line, Topic, Message, sync, generate_complete_routing_name(Module)).

% do parse_transfrorm to pub/7 wherever it possible to avoid atom construction during runtime
pub(Module, Process, Line, Topic, Message, hybrid, EtsName) ->
    WhoGetWhileSync = load_routing_and_send(EtsName, Topic, Message, []),
    gen_server:cast(erlroute, {new_msg, Module, Process, Line, Topic, Message, EtsName, WhoGetWhileSync});
pub(Module, Process, Line, Topic, Message, async, EtsName) ->
    gen_server:cast(erlroute, {new_msg, Module, Process, Line, Topic, Message, EtsName, []}).

% load routing recursion 
load_routing_and_send(EtsName, Topic, Message, Acc) ->
    try ets:lookup(EtsName, Topic) of 
        [] when Topic =/= <<"*">> -> 
            load_routing_and_send(EtsName, <<"*">>, Message, Acc);
        [] ->
            Acc;
        Routes when Topic =/= <<"*">> -> 
            % send to wildcard-topic subscribers
            WhoGet = send(Routes, Message, Acc),
            load_routing_and_send(EtsName, <<"*">>, Message, WhoGet);
        Routes ->
            send(Routes, Message, Acc)
    catch
        _:_ ->
            Acc
    end.

% sending to standart process
send([#complete_routes{dest_type = 'process', dest = Process, method = Method}|T], Message, Acc) ->
    case Method of
        info -> Process ! Message;
        cast -> gen_server:cast(Process, Message);
        call -> gen_server:call(Process, Message)
    end,
    send(T, Message, [Process|Acc]);

% sending to poolboy pool
send([#complete_routes{dest_type = 'poolboy', dest = PoolName, method = Method}|T], Message, Acc) ->
    try poolboy:checkout(PoolName) of
        Worker when is_pid(Worker) -> 
            gen_server:cast(Worker, Message),
            case Method of
                info -> Worker ! Message;
                cast -> gen_server:cast(Worker, Message);
                call -> gen_server:call(Worker, Message)
            end,
            poolboy:checkin(PoolName, Worker);
        _ ->
            error_logger:error_msg("Worker not is pid")
    catch
        X:Y -> error_logger:error_msg("Looks like pool ~p not found, got error ~p with reason ~p",[PoolName,X,Y])
    end,
    send(T, Message, Acc);

% final clause for empty list
send([], _Message, Acc) -> Acc.

% ================================ end of pub part =============================
% ----------------------------------- sub part ---------------------------------

% @doc Subscribe to the message flow.
% Erlroute support subscription to pid, to registered process name or to the message pool like https://github.com/devinus/poolboy[Poolboy^].
% For the process subscribed by pid or registered name it just send message.
% For the pools for every new message it checkout one worker, then send message to that worker and then checkin.

-spec sub(FlowSource) -> ok when
    FlowSource  :: flow_source() | nonempty_list().

sub(FlowSource) -> sub(FlowSource, {process, self(), info}).

-spec sub(FlowSource,FlowDest) -> ok when
    FlowSource  :: flow_source() | nonempty_list(),
    FlowDest    :: flow_dest().

% we don't want to crash gen_server process, so we validating data on caller side
sub(FlowSource = #flow_source{module = Module, topic = Topic}, {DestType, Dest, Method}) when 
        is_atom(Module),
        is_binary(Topic),
        DestType =:= 'process' orelse DestType =:= 'poolboy',
        is_pid(Dest) orelse is_atom(Dest),
        Method =:= 'info' orelse Method =:= 'cast' orelse Method =:= 'call' ->
    gen_server:call(?MODULE, {subscribe, FlowSource, {DestType, Dest, Method}});

% when Dest is pid() or atom
sub(FlowSource, FlowDest) when is_pid(FlowDest) orelse is_atom(FlowDest) ->
    sub(FlowSource, {process, FlowDest, info});

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

subscribe(#flow_source{module = undefined, topic = _Topic}, {_DestType, _Dest, _Method}) ->
    ok; % temporary. need implement lookup_by_topic

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
            % then need try match this topic from '$erlroute_topics'
    end.

% ================================ end of sub part =============================
% ----------------------------------- unsub part -------------------------------

unsubscribe(_FlowSource,_FlowDest) -> ok.
% ================================ end of sub part =============================




% ---------------------------------other functions -----------------------------
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
      Result    ::  ets:tid() | ok.

route_table_must_present(EtsName) ->
   case ets:info(EtsName, size) of
       undefined -> 
            ets:new(EtsName, [bag, protected, 
                {read_concurrency, true}, 
                {keypos, #complete_routes.topic}, 
                named_table
            ]);
       _ ->
           ok
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
split_topic(<<>>, WAcc, Result) ->
    lists:reverse([lists:reverse(WAcc)|Result]);
split_topic(<<2#00101110:8, Rest/binary>>, WAcc, Result) ->
    split_topic(Rest, [], [lists:reverse(WAcc)|Result]);
split_topic(<<Char:8, Rest/binary>>, WAcc, Result) ->
    split_topic(Rest, [Char|WAcc], Result);
split_topic(<<>>, [], []) -> [].
