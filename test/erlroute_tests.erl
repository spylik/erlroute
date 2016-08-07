-module(erlroute_tests).

-compile({parse_transform, erlroute_transform}).

-include_lib("eunit/include/eunit.hrl").
-include("erlroute.hrl").

-define(TESTSERVER, erlroute).


% --------------------------------- fixtures ----------------------------------

publish(Msg) ->
    erlroute:pub(Msg).

publish(Topic,Msg) ->
    erlroute:pub(Topic, Msg).

% tests for cover standart otp behaviour
otp_test_() ->
    {setup,
        fun disable_output/0, % setup
        {inorder,
            [
                {<<"Application able to start via application:start()">>,
                    fun() ->
                        application:start(?TESTSERVER),
                        ?assertEqual(
                            ok,
                            application:ensure_started(?TESTSERVER)
                        ),
                        ?assertEqual(
                            true,
                            is_pid(whereis(?TESTSERVER))
                        )
                    end},
                {<<"Application able to stop via application:stop()">>,
                    fun() ->
                        application:stop(?TESTSERVER),
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"Application able to start via ?TESTSERVER:start_link()">>,
                    fun() ->
                        ?TESTSERVER:start_link(),
                        ?assertEqual(
                            true,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"Application able to stop via ?TESTSERVER:stop()">>,
                    fun() ->
                        ?assertExit({normal,{gen_server,call,[?TESTSERVER,stop]}}, ?TESTSERVER:stop()),
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"Application able to start and stop via ?TESTSERVER:start_link() / ?TESTSERVER:stop(sync)">>,
                    fun() ->
                        ?TESTSERVER:start_link(),
                        ?assertExit({normal,{gen_server,call,[?TESTSERVER,stop]}}, ?TESTSERVER:stop(sync)),
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"Application able to start and stop via ?TESTSERVER:start_link() ?TESTSERVER:stop(async)">>,
                    fun() ->
                        ?TESTSERVER:start_link(),
                        ?TESTSERVER:stop(async),
                        timer:sleep(1), % for async cast
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end}

            ]
        }
    }.

% tests which doesn't require started erlroute as gen_server process
erlroute_non_started_test_() ->
    {setup,
        fun cleanup/0,
        {inparallel,
            [
                {<<"When erlroute doesn't start, ets-table msg_routes must be undefined">>, 
                    fun() -> 
                        ?assertEqual(
                            undefined, 
                            ets:info(msg_routes)
                        ) 
                    end},
        
                {<<"When erlroute doesn't start, process erlroute must be unregistered">>, 
                    fun() ->
                        ?assertEqual(
                            false, 
                            is_pid(whereis(?TESTSERVER))
                        )
                    end},
        
                {<<"generate_routing_name must generate correct ets table name when Type is by_module_name">>,
                    fun() ->
                        Type = by_module_name,
                        Source = test_producer,
                        ?assertEqual(
                            erlroute:generate_routing_name(Source), 
                            '$erlroute_test_producer'
                        )
                    end}
            ]
        }
    }.

% tests which require started erlroute as gen_server process
erlroute_started_test_() -> 
    {setup,
        fun setup_start/0,
        fun cleanup/1,
        {inparallel, 
             [
                {<<"When erlroute started is must be register as erlroute">>, 
                    fun() -> 
                        ?assertEqual(
                            true, 
                            is_pid(whereis(?TESTSERVER))
                        ) 
                    end},
                {<<"Unknown gen_calls messages must do not crash gen_server">>,
                   fun() -> 
                       _ = gen_server:call(?TESTSERVER, {unknown, message}),
                       timer:sleep(1), % for async cast
                       ?assertEqual(
                           true, 
                           is_pid(whereis(?TESTSERVER))
                       ) 
                   end},

                {<<"Unknown gen_cast messages must do not crash gen_server">>,
                   fun() -> 
                       gen_server:cast(?TESTSERVER, {unknown, message}),
                       timer:sleep(1), % for async cast
                       ?assertEqual(
                           true, 
                           is_pid(whereis(?TESTSERVER))
                       ) 
                   end},

                {<<"Unknown gen_info messages must do not crash gen_server">>,
                   fun() -> 
                       ?TESTSERVER ! {unknown, message},
                       timer:sleep(1), % for async cast
                       ?assertEqual(
                           true, 
                           is_pid(whereis(?TESTSERVER))
                       ) 
                   end}
            ]
        }
    }.

erlroute_messaging_test_() ->
    {setup,
        fun setup_start/0,
        fun cleanup/1,
        {inparallel, 
             [
                {<<"After sub/2 with full parameters and topic <<\"*\">>, ets tables must present and route entry must present in ets">>, 
                    fun() ->
                        % source 
                        Module = mlibs:random_atom(),
                        Topic = <<"*">>,
                        % dest
                        DestType = process,
                        Dest = self(),

                        EtsTable = erlroute:generate_routing_name(Module),
                        erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest}),
                        MS = [{
                                #active_route{
                                    topic = Topic, 
                                    dest_type = DestType,
                                    dest = Dest
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/2 with full parameters and topic <<\"*\">> (reversed), ets tables must present and route entry must present in ets">>, 
                    fun() ->
                        % source 
                        Module = mlibs:random_atom(),
                        Topic = <<"*">>,
                        % dest
                        DestType = process,
                        Dest = self(),

                        EtsTable = erlroute:generate_routing_name(Module),
                        erlroute:sub([{topic, Topic}, {module, Module}], {DestType, Dest}),
                        MS = [{
                                #active_route{
                                    topic = Topic, 
                                    dest_type = DestType,
                                    dest = Dest
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},

                {<<"After sub/2 with full parameters and topic <<\"*\">> (reversed), ets tables must present and route entry must present in ets">>, 
                    fun() ->
                        % source 
                        Module = mlibs:random_atom(),
                        Topic = <<"*">>,
                        % dest
                        DestType = process,
                        Dest = self(),

                        EtsTable = erlroute:generate_routing_name(Module),
                        erlroute:sub([{topic, Topic}, {module, Module}], {DestType, Dest}),
                        MS = [{
                                #active_route{
                                    topic = Topic, 
                                    dest_type = DestType,
                                    dest = Dest
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},

                {<<"After sub/2 without topic it should subscribe to <<\"*\">>">>, 
                    fun() ->
                        % source 
                        Module = mlibs:random_atom(),
                        Topic = <<"*">>,
                        % dest
                        DestType = process,
                        Dest = self(),

                        EtsTable = erlroute:generate_routing_name(Module),
                        erlroute:sub([{module, Module}], {DestType, Dest}),
                        MS = [{
                                #active_route{
                                    topic = Topic, 
                                    dest_type = DestType,
                                    dest = Dest
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},
       
                {<<"After multiple sync sub/6 attempts, ets tables must have only one route entry for each type/source">>, 
                    fun() -> 
                         % source 
                         Module = mlibs:random_atom(),
                         Topic = <<"*">>,
                         % dest
                         DestType = process,
                         Dest = self(),
                
                         EtsTable = erlroute:generate_routing_name(Module),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest}),
                         MS = [{
                                 #active_route{
                                     topic = Topic, 
                                     dest_type = DestType,
                                     dest = Dest
                                 },
                                 [],
                                 [true]
                             }],
                         ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end}
%       
%                {<<"After sync unsub/6, ets table must do not contain route entry">>,
%                    fun() ->
%                        Type = by_module_name,
%                        Source = test_producer_unsub_sync6,
%                        Topic = <<"*">>,
%                        Dest = self(),
%                        DestType = pid,
%                        EtsTable = erlroute:generate_routing_name(Type, Source),
%                        MS = [{
%                                #active_route{
%                                    topic = Topic, 
%                                    dest = Dest, 
%                                    dest_type = DestType
%                                },
%                                [],
%                                [true]
%                            }],
%                        erlroute:sub(sync, Type, Source, Topic, Dest, DestType),
%                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
%                        erlroute:unsub(sync, Type, Source, Topic, Dest, DestType),
%                        ?assertEqual(0, ets:select_count(EtsTable, MS))
%                    end},
%       
%               {<<"Sync unsub/5 must work same as unsub/5 with DestType=pid">>,
%                   fun() ->
%                       Type = by_module_name,
%                       Source = test_producer_unsub_sync5,
%                       Topic = <<"*">>,
%                       Dest = self(),
%                       DestType = pid,
%                       EtsTable = erlroute:generate_routing_name(Type, Source),
%                       MS = [{
%                               #active_route{
%                                   topic = Topic, 
%                                   dest = Dest, 
%                                   dest_type = DestType
%                               },
%                               [],
%                               [true]
%                           }],
%                       erlroute:sub(sync, Type, Source, Topic, Dest),
%                       ?assertEqual(1, ets:select_count(EtsTable, MS)),
%                       erlroute:unsub(sync, Type, Source, Topic, Dest),
%                       ?assertEqual(0, ets:select_count(EtsTable, MS))
%                   end},
%       
%               % ---------------------- end of sync tests ---------------------- %
%               % ------------------------- async tests ------------------------- %
%               {<<"After async sub/6, ets tables must present and route entry must present in ets">>, 
%                   fun() -> 
%                       Type = by_module_name,
%                       Source = test_producer_async6,
%                       Topic = <<"*">>,
%                       Dest = self(),
%                       DestType = pid,
%                       EtsTable = erlroute:generate_routing_name(Type, Source),
%                       erlroute:sub(async, Type, Source, Topic, Dest, DestType),
%                       MS = [{
%                               #active_route{
%                                   topic = Topic, 
%                                   dest = Dest, 
%                                   dest_type = DestType
%                               },
%                               [],
%                               [true]
%                           }],
%                       timer:sleep(75), % for async cast
%                       ?assertEqual(1, ets:select_count(EtsTable, MS))
%                   end},
%
%               {<<"After multiple async sub/6 attempts, ets tables must have only one route entry for each type/source">>, 
%                   fun() -> 
%                       Type = by_module_name,
%                       Source = test_producer_sub_async6_multiple,
%                       Topic = <<"*">>,
%                       Dest = self(),
%                       DestType = pid,
%                       EtsTable = erlroute:generate_routing_name(Type, Source),
%                       erlroute:sub(async, Type, Source, Topic, Dest, DestType),
%                       erlroute:sub(async, Type, Source, Topic, Dest, DestType),
%                       erlroute:sub(async, Type, Source, Topic, Dest, DestType),
%                       MS = [{
%                               #active_route{
%                                   topic = Topic, 
%                                   dest = Dest, 
%                                   dest_type = DestType
%                               },
%                              [],
%                              [true]
%                           }],
%                       timer:sleep(75), % for async cast
%                       ?assertEqual(1, ets:select_count(EtsTable, MS))
%                   end},
%       
%               {<<"Async sub/5 must work same as sub/6 with DestType=pid">>, 
%                   fun() -> 
%                       Type = by_module_name,
%                       Source = test_producer_sub_async5,
%                       Topic = <<"*">>,
%                       Dest = self(),
%                       DestType = pid,
%                       EtsTable = erlroute:generate_routing_name(Type, Source),
%                       erlroute:sub(async, Type, Source, Topic, Dest),
%                       MS = [{
%                               #active_route{
%                                   topic = Topic, 
%                                   dest = Dest, 
%                                   dest_type = DestType
%                               },
%                               [],
%                               [true]
%                           }],
%                       timer:sleep(75), % for async cast
%                       ?assertEqual(1, ets:select_count(EtsTable, MS))
%                   end},
%
%               {<<"sub/4 must work same as sub/6 with sync DestType=pid">>, 
%                   fun() -> 
%                       Type = by_module_name,
%                       Source = test_producer_sub_async5,
%                       Topic = <<"*">>,
%                       Dest = self(),
%                       DestType = pid,
%                       EtsTable = erlroute:generate_routing_name(Type, Source),
%                       erlroute:sub(Type, Source, Topic, Dest),
%                       MS = [{
%                               #active_route{
%                                   topic = Topic, 
%                                   dest = Dest, 
%                                   dest_type = DestType
%                               },
%                               [],
%                               [true]
%                           }],
%                       timer:sleep(75), % for async cast
%                       ?assertEqual(1, ets:select_count(EtsTable, MS))
%                   end},
%
%
%               {<<"After async unsub/6, ets table must do not contain route entry">>,
%                   fun() ->
%                       Type = by_module_name,
%                       Source = test_producer_unsub_async6,
%                       Topic = <<"*">>,
%                       Dest = self(),
%                       DestType = pid,
%                       EtsTable = erlroute:generate_routing_name(Type, Source),
%                       MS = [{
%                               #active_route{
%                                   topic = Topic, 
%                                   dest = Dest, 
%                                   dest_type = DestType
%                               },
%                               [],
%                               [true]
%                           }],
%                       erlroute:sub(async, Type, Source, Topic, Dest, DestType),
%                       timer:sleep(75), % for async cast
%                       ?assertEqual(1, ets:select_count(EtsTable, MS)),
%                       erlroute:unsub(async, Type, Source, Topic, Dest, DestType),
%                       timer:sleep(75), % for async cast
%                       ?assertEqual(0, ets:select_count(EtsTable, MS))
%                   end},
%       
%               {<<"Async unsub/5 must work same as unsub/6 with DestType=pid">>,
%                   fun() ->
%                       Type = by_module_name,
%                       Source = test_producer_unsub_async5,
%                       Topic = <<"*">>,
%                       Dest = self(),
%                       DestType = pid,
%                       EtsTable = erlroute:generate_routing_name(Type, Source),
%                       MS = [{
%                               #active_route{
%                                   topic = Topic, 
%                                   dest = Dest, 
%                                   dest_type = DestType
%                               },
%                               [],
%                               [true]
%                           }],
%                       erlroute:sub(async, Type, Source, Topic, Dest),
%                       timer:sleep(75), % for async cast
%                       ?assertEqual(1, ets:select_count(EtsTable, MS)),
%                       erlroute:unsub(async, Type, Source, Topic, Dest),
%                       timer:sleep(75), % for async cast
%                       ?assertEqual(0, ets:select_count(EtsTable, MS))
%                   end},
%
%               {<<"Async unsub/4 must work same as unsub/6 with async DestType=pid">>,
%                   fun() ->
%                       Type = by_module_name,
%                       Source = test_producer_unsub_async4,
%                       Topic = <<"*">>,
%                       Dest = self(),
%                       DestType = pid,
%                       EtsTable = erlroute:generate_routing_name(Type, Source),
%                       MS = [{
%                               #active_route{
%                                   topic = Topic, 
%                                   dest = Dest, 
%                                   dest_type = DestType
%                               },
%                               [],
%                               [true]
%                           }],
%                       erlroute:sub(Type, Source, Topic, Dest),
%                       timer:sleep(75), % for async cast
%                       ?assertEqual(1, ets:select_count(EtsTable, MS)),
%                       erlroute:unsub(Type, Source, Topic, Dest),
%                       timer:sleep(75), % for async cast
%                       ?assertEqual(0, ets:select_count(EtsTable, MS))
%                   end},
%               % ---------------------- end of async tests --------------------- %
%
%               {<<"Erlroute able to deliver message to single subscriber with specified topic">>,
%                   fun() ->
%                       Type = by_pid,
%                       Source = self(),
%                       SendTopic = <<"test.topic">>,
%                       SubTopic = <<"test.topic">>,
%                       Pid = spawn_link(
%                           fun() ->
%                                  receive
%                                      {From, Ref} -> 
%                                          From ! {got, Ref}
%                                  after 50 -> false
%                                  end
%                           end),
%                       erlroute:sub(Type, Source, SubTopic, Pid),
%                       Msg = make_ref(),
%                       timer:sleep(5),
%                       erlroute:pub(?MODULE, self(), ?LINE, SendTopic, {self(), Msg}),
%                       Ack = 
%                           receive
%                               {got, Msg} -> Msg
%                           after 50 -> false
%                           end,
%                       ?assertEqual(Msg, Ack)
%               end},
%
%               {<<"Erlroute must do not deliver message when consumer subscribe to another topic than producer send and consumer do not use <<\"*\">> for subscribe">>,
%                   fun() ->
%                       Type = by_pid,
%                       Source = self(),
%                       SendTopic = <<"test.topic">>,
%                       SubTopic = <<"test.topic1">>,
%                       Pid = spawn_link(
%                           fun() ->
%                                  receive
%                                      {From, Ref} -> 
%                                          From ! {got, Ref}
%                                  after 50 -> false
%                                  end
%                           end),
%                       erlroute:sub(Type, Source, SubTopic, Pid),
%                       Msg = make_ref(),
%                       timer:sleep(5),
%                       erlroute:pub(?MODULE, self(), ?LINE, SendTopic, {self(), Msg}),
%                       Ack = 
%                           receive
%                               {got, Msg} -> Msg
%                           after 50 -> false
%                           end,
%                       ?assertEqual(false, Ack)
%               end},
%
%               {<<"Consumers subscribed to <<\"*\">> topic must able to get all messages from specified producer">>,
%                   fun() ->
%                       Type = by_pid,
%                       Source = self(),
%                       SendTopic = <<"test.topic">>,
%                       SubTopic = <<"*">>,
%                       Pid = spawn_link(
%                           fun() ->
%                                  receive
%                                      {From, Ref} -> 
%                                          From ! {got, Ref}
%                                  after 50 -> false
%                                  end
%                           end),
%                       erlroute:sub(Type, Source, SubTopic, Pid),
%                       Msg = make_ref(),
%                       timer:sleep(5),
%                       erlroute:pub(?MODULE, self(), ?LINE, SendTopic, {self(), Msg}),
%                       Ack = 
%                           receive
%                               {got, Msg} -> Msg
%                           after 50 -> false
%                           end,
%                       ?assertEqual(Msg, Ack)
%               end}

             ]
         }
     }.

parse_transform_tes() ->
    {setup,
        fun setup_start/0,
        {inparallel, 
             [
                {<<"pub/1 should transform to pub/5 (in module clause) and consumer able to get message">>,
                    fun() ->
                        Type = by_pid,
                        Source = self(),
                        SubTopic = <<"erlroute_tests.14">>,
                        Pid = spawn_link(
                            fun() ->
                                   receive
                                       {From, Ref} -> 
                                           From ! {got, Ref}
                                   after 50 -> false
                                   end
                            end),
                        erlroute:sub(Type, Source, SubTopic, Pid),
                        Msg = make_ref(),
                        timer:sleep(5),
                        publish({self(), Msg}),
                        Ack = 
                            receive
                                {got, Msg} -> Msg
                            after 50 -> false
                            end,
                        ?assertEqual(Msg, Ack)
                end},

                {<<"pub/2 should transform to pub/5 (in module clause) and consumer able to get message">>,
                    fun() ->
                        Type = by_pid,
                        Source = self(),
                        SendTopic = <<"test.topic">>,
                        SubTopic = <<"*">>,
                        Pid = spawn_link(
                            fun() ->
                                   receive
                                       {From, Ref} -> 
                                           From ! {got, Ref}
                                   after 50 -> false
                                   end
                            end),
                        erlroute:sub(Type, Source, SubTopic, Pid),
                        Msg = make_ref(),
                        timer:sleep(5),
                        publish(SendTopic, {self(), Msg}),
                        Ack = 
                            receive
                                {got, Msg} -> Msg
                            after 50 -> false
                            end,
                        ?assertEqual(Msg, Ack)
                end}
            ]
        }
    }.

setup_start() -> 
%    disable_output(),
    start_server().

disable_output() ->
    error_logger:tty(false).

cleanup() -> cleanup(true).

cleanup(_) -> 
    application:stop(erlroute).

start_server() -> application:ensure_started(?TESTSERVER).
