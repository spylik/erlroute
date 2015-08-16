%% --------------------------------------------------------------------------------
%% File:    erlroute.erl
%% @author  Oleksii Semilietov <spylik@gmail.com>
%%
%% @doc
%% This source code contin static & dynamic message routing rules from one module or process 
%% to another. Static routing a little bit faster than ETS-based dynamic pub/sub,
%% but need to be hardcoded.
%%
%% It is not pub/sub queue broker it is pub/sub router without queue-logic overhead.
%% This module use native erlang queue-logic and pure erlang message passing.
%% It is much faster than RabbitMQ. 
%% 
%% Every publisher by default have 2 dynamic routes - by_module_name and by_pid. 
%% Subscribes can subscribe for messages from specified module or process id.
%% 
%% Every static routing rules we should close by dyn_route/4 function for add 
%% dynamic futures. Also in dyn_route function we pushes data to RabbitMQ broker.
%%
%% Functions from this process can be called directly via gen_server:call 
%% or gen_server:cast functions. Of course direct functions works a little bit faster, but 
%% we also can use message passing when need this future.
%% @end
%% --------------------------------------------------------------------------------

-module(erlroute).

-include("erlroute.hrl").

% gen server is here
-behaviour(gen_server).

% gen_server api
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

% public api 
-export([
        start_link/0,
        pub/4,
        sub/5,
        sub/6,
        unsub/5,
        unsub/6
    ]).

%-compile([export_all]).

% we will use ?MODULE as servername
-define(SERVER, ?MODULE).

% --------------------------------- gen_server part --------------------------------------

% star/stop api
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

% we going to create ETS tables for dynamic routing rules in init section
init([]) ->
    ets:new(
        msg_routes, [
            set, 
            protected, 
            {keypos, #msg_routes.ets_name}, 
            {read_concurrency, true}, 
            named_table
        ]),
    {ok, undefined}.

%--------------handle_call----------------

handle_call({sub, Type, Source, Topic, Dest, DestType}, _From, State) ->
    Result = subscribe(Type, Source, Topic, Dest, DestType),
    {reply, Result, State};

handle_call({unsub, Type, Source, Topic, Dest, DestType}, _From, State) ->
    Result = unsubscribe(Type, Source, Topic, Dest, DestType),
    {reply, Result, State};

% handle_call for all other thigs
handle_call(Msg, _From, State) ->
    error_logger:warning_msg("we are in undefined handle_call with message ~p\n",[Msg]),
    {reply, ok, State}.
%-----------end of handle_call-------------


%--------------handle_cast-----------------

handle_cast({sub, Type, Source, Topic, Dest, DestType}, State) ->
    subscribe(Type, Source, Topic, Dest, DestType),
    {noreply, State};

handle_cast({unsub, Type, Source, Topic, Dest, DestType}, State) ->
    unsubscribe(Type, Source, Topic, Dest, DestType),
    {noreply, State};

% handle_cast for all other thigs
handle_cast(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle_cast with message ~p\n",[Msg]),
    {noreply, State}.
%-----------end of handle_cast-------------


%--------------handle_info-----------------
%% handle_info for all other thigs
handle_info(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle_info with message ~p\n",[Msg]),
    {noreply, State}.
%-----------end of handle_info-------------


terminate(Reason, State) ->
    {noreply, Reason, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% ===================================== end of gen_server part ==================================
% ----------------------------------------- pub part --------------------------------------------
-spec pub(Module, Pid, Topic, Message) -> ok when
    Module  ::  atom(),
    Pid     ::  pid() | atom(),
    Topic   ::  binary(),
    Message ::  term().

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% static hardcoded rules can be here %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% final clause - if we don't mutch before any clueses, we just going to dynamic routing part
pub(Module, Pid, Topic, Message) ->
    dyn_route(Module, Pid, Topic, Message).

% dynamic ETS-routes 
dyn_route(Module, Pid, Topic, Message) ->
    % first - we going to send by_module_name because identify 
    % process by module name is more often
    load_routing_and_send(generate_routing_name(by_module_name, Module), Topic, Message),
    
    % and second - by_pid or registered name (atom)
    load_routing_and_send(generate_routing_name(by_pid, Pid), Topic, Message).


% load routing recursion 
load_routing_and_send(EtsName, Topic, Message) ->
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
send([{active_route,_,Pid,pid}|T], Message) ->
    Pid ! Message,
    send(T, Message);
% sending to poolboy pool
send([{active_route,_,Pool,poolboy_pool}|T], Message) ->
    try poolboy:checkout(Pool) of
        Worker when is_pid(Worker) -> 
            gen_server:cast(Worker, Message),
            poolboy:checkin(Pool, Worker);
        _ ->
            error_logger:error_msg("Worker not is pid")
    catch
        X:Y -> error_logger:error_msg("Looks like pool ~p not found, got error ~p with reason ~p",[Pool,X,Y])
    end,
    send(T,Message);
send([], _Message) -> ok.

% ================================ end of pub part =================================
% ----------------------------------- sub part -------------------------------------
% @doc
% We create dynamic rules when going to subscirbe.
% While ETS route table not present, we do not waste time for processing dynamic routes
% @end

% async/sync subscribe to pid
-spec sub(sync | async, by_module_name | by_pid, Source, Topic, Dest) -> ok when
    Source  ::  pid() | atom() | term(),
    Topic   ::  binary(),
    Dest    ::  pid() | atom().

sub(async, Type, Source, Topic, Dest) ->
    sub(async, Type, Source, Topic, Dest, pid).

% async/sync subscribe (to pid or poolboy_pool)
-spec sub(sync | async, by_module_name | by_pid, Source, Topic, Dest, pid | poolboy_pool) -> ok when
    Source  ::  pid() | atom() | term(),
    Topic   ::  binary(),
    Dest    ::  pid() | atom().

sub(async, Type, Source, Topic, Dest, DestType) ->
    gen_server:cast(?MODULE, {sub, Type, Source, Topic, Dest, DestType});
sub(sync, Type, Source, Topic, Dest, DestType) ->
    gen_server:call(?MODULE, {sub, Type, Source, Topic, Dest, DestType}).

% subscribe routine (called from gen_server call/cast)
-spec subscribe(by_module_name | by_pid, Source, Topic, Dest, pid | poolboy_pool) -> ok when
    Source  ::  pid() | atom() | term(),
    Topic   ::  binary(),
    Dest    ::  pid() | atom().

subscribe(Type, Source, Topic, Dest, DestType) ->
    EtsName = generate_routing_name(Type, Source),
    check_route_table_present(EtsName),
    ets:insert(EtsName, #active_route{topic=Topic,dest=Dest,dest_type=DestType}).

% check if ets routing table is present, on falure - let's create it 
check_route_table_present(EtsName) ->
    % todo: we need find most effective way to check table is present
    % now looks like ets:first works fastest, but need more research 
    try ets:first(EtsName) 
    catch 
        _:_ ->
            ets:new(EtsName, [bag, protected, {read_concurrency, true}, {keypos, #active_route.topic}, named_table]),
            ets:insert(msg_routes, #msg_routes{ets_name=EtsName}),
            {created, EtsName}
    end.

% ================================ end of sub part =================================
% ----------------------------------- unsub part -------------------------------------
% @doc
% When we going to unsubscribe, we just delete record from ets-table
% @end

% async/sync unsubscribe from pid
-spec unsub(sync | async, by_module_name | by_pid, Source, Topic, Dest) -> ok when
    Source  ::  pid() | atom() | term(),
    Topic   ::  binary(),
    Dest    ::  pid() | atom().

unsub(async, Type, Source, Topic, Dest) ->
    unsub(async, Type, Source, Topic, Dest, pid).

% async/sync unsubscribe (from pid or poolboy_pool)
-spec unsub(sync | async, by_module_name | by_pid, Source, Topic, Dest, pid | poolboy_pool) -> ok when
    Source  ::  pid() | atom() | term(),
    Topic   ::  binary(),
    Dest    ::  pid() | atom().

unsub(async, Type, Source, Topic, Dest, DestType) ->
    gen_server:cast(?MODULE, {unsub, Type, Source, Topic, Dest, DestType});
unsub(sync, Type, Source, Topic, Dest, DestType) ->
    gen_server:call(?MODULE, {unsub, Type, Source, Topic, Dest, DestType}).

% unsubscribe routine (called from gen_server call/cast)
-spec unsubscribe(by_module_name | by_pid, Source, Topic, Dest, pid | poolboy_pool) -> ok when
    Source  ::  pid() | atom() | term(),
    Topic   ::  binary(),
    Dest    ::  pid() | atom().

unsubscribe(Type, Source, Topic, Dest, DestType) ->
    EtsName = generate_routing_name(Type, Source),
    ets:match_delete(EtsName, #active_route{topic=Topic, dest=Dest, dest_type=DestType}).
% ================================ end of unsub part =================================
% ----------------------------------- other functions --------------------------------

% generate routing name which should used for ets table
-spec generate_routing_name(by_module_name | by_pid, Source) -> ok when
    Source  ::  pid() | atom() | term().

generate_routing_name(Type, Source) when is_atom(Source)->
    list_to_atom(lists:append(["route_", atom_to_list(Type), "_", atom_to_list(Source)]));
generate_routing_name(Type, Source) when is_pid(Source)->
    list_to_atom(lists:append(["route_", atom_to_list(Type), "_", pid_to_list(Source)])).
