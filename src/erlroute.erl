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
        sub/2
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
    _ = ets:new(topics, [
            set,
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

-spec pub(Module, Process, Line, Topic, Message) -> ok when
    Module  ::  module(),
    Process ::  proc(),
    Line    ::  pos_integer(),
    Topic   ::  binary(),
    Message ::  term().

pub(Module, Process, Line, Topic, Message) ->
    pub(Module, Process, Line, Topic, Message, generate_routing_name(Module)).

% do parse_transfrorm to pub/6 wherever it possible to avoid atom construction during runtime
pub(Module, Process, Line, Topic, Message, EtsName) ->
    io:format("Module ~p, Process ~p, Topic ~p, Message ~p", [Module, Process, Topic, Message]),
    load_routing_and_send(EtsName, Topic, Message),
    % keep stats and update routes when need
    gen_server:cast(erlroute, {new_msg, Module, Process, Line, Topic, Message}).

% load routing recursion 
load_routing_and_send(EtsName, Topic, Message) ->
    io:format("here"),
    try ets:lookup(EtsName, Topic) of 
        [] when Topic =/= <<"*">> -> 
            load_routing_and_send(EtsName, <<"*">>, Message);
        [] ->
            ok;
        Routes when Topic =/= <<"*">> -> 
            % send to wildcard-topic subscribers
            send(Routes, Message),
            load_routing_and_send(EtsName, <<"*">>, Message);
        Routes ->
            send(Routes, Message)
    catch
        _:_ ->
            ok
    end.

% sending to standart process
send([#active_route{dest_type = 'process', dest = Process}|T], Message) ->
    Process ! Message,
    send(T, Message);

% sending to poolboy pool
send([#active_route{dest_type = 'poolboy', dest = PoolName}|T], Message) ->
    try poolboy:checkout(PoolName) of
        Worker when is_pid(Worker) -> 
            gen_server:cast(Worker, Message),
            poolboy:checkin(PoolName, Worker);
        _ ->
            error_logger:error_msg("Worker not is pid")
    catch
        X:Y -> error_logger:error_msg("Looks like pool ~p not found, got error ~p with reason ~p",[PoolName,X,Y])
    end,
    send(T,Message);

% final clause for empty list
send([], _Message) -> ok.

% ================================ end of pub part =============================
% ----------------------------------- sub part ---------------------------------

% @doc Subscribe to the message flow.
% Erlroute support subscription to pid, to registered process name or to the message pool like https://github.com/devinus/poolboy[Poolboy^].
% For the process subscribed by pid or registered name it just send message.
% For the pools for every new message it checkout one worker, then send message to that worker and then checkin.

-spec sub(FlowSource,FlowDest) -> ok when
    FlowSource  :: flow_source() | nonempty_list(),
    FlowDest    :: flow_dest().

% we don't want to crash gen_server process, so we validating data on caller side
sub(FlowSource = #flow_source{module = Module, topic = Topic}, {DestType, Dest}) when 
        is_atom(Module),
        is_binary(Topic),
        DestType =:= 'process' orelse DestType =:= 'poolboy',
        is_pid(Dest) orelse is_atom(Dest) ->
    gen_server:call(?MODULE, {subscribe, FlowSource, {DestType, Dest}});

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

subscribe(#flow_source{module = Module, topic = Topic}, {DestType, Dest}) ->
    case Module of
        undefined -> ok;  % temporary. need implement lookup_by_topic
        _ ->
            EtsName = generate_routing_name(Module),
            _ = route_table_must_present(EtsName),
            ets:insert(EtsName, #active_route{topic=Topic, dest_type=DestType, dest=Dest})
    end.


% ================================ end of sub part =============================
% ----------------------------------- unsub part -------------------------------

unsubscribe(_FlowSource, _FlowDest) -> ok.

%unsubscribe(Type, FlowSource, Topic, Dest, DestType) ->
%    EtsName = generate_routing_name(Type, FlowSource),
%    ets:match_delete(EtsName, #active_route{topic=Topic, dest=Dest, dest_type=DestType}).

% ================================ end of sub part =============================




% ---------------------------------other functions -----------------------------
% generate routing name which should used for ets table
-spec generate_routing_name(Module) -> ok when
    Module  ::  module().

generate_routing_name(Module) when is_atom(Module)->
    list_to_atom("$erlroute_" ++ atom_to_list(Module)).

% check if ets routing table is present, on falure - let's create it 
-spec route_table_must_present (EtsName) -> ok | {created,ok} when
      EtsName   ::  atom().

route_table_must_present(EtsName) ->
   case ets:info(EtsName, size) of
       undefined -> 
            ets:new(EtsName, [bag, protected, 
                {read_concurrency, true}, 
                {keypos, #active_route.topic}, 
                named_table
            ]);
       _ ->
           ok
   end.

% @doc split binary topic to the list
%-spec split_topic_key(Key) -> Result when
%    Key :: binary(),
%    Result :: nonempty_list().
%
%split_topic_key(Key) ->
%    binary:split(Key, <<".">>).
