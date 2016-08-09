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
                {<<"When erlroute doesn't start, ets-table '$erlroute_topics' must be undefined">>, 
                    fun() -> 
                        ?assertEqual(
                            undefined, 
                            ets:info('$erlroute_topics')
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
                   end},

                {<<"When erlroute start, ets-table '$erlroute_topics' must be present">>, 
                    fun() -> 
                        ?assertNotEqual(
                            undefined, 
                            ets:info('$erlroute_topics')
                        ) 
                    end
                }

            ]
        }
    }.

% test pub_routine
erlroute_msg_ack_test_() ->
    {setup,
        fun setup_start/0,
        fun cleanup/1,
        {inorder,
            [
                {<<"After pub we must have one record in topics ets">>, 
                    fun() ->
                        % source
                        ?assertEqual(0, ets:info('$erlroute_topics', size)),
                        Module = mlibs:random_atom(),
                        SendTopic = <<"testtopic">>,
                        Process = self(),
                        Msg = make_ref(),
                        erlroute:pub(Module, Process, ?LINE, SendTopic, Msg),
                        timer:sleep(5),
                        ?assertEqual(1, ets:info('$erlroute_topics', size))
                    end},
                {<<"After pub we must have two record in topics ets with right data">>, 
                    fun() ->
                        % source 
                        Module = mlibs:random_atom(),
                        Topic = <<"testtopic">>,
                        Process = self(),
                        Msg = make_ref(),
                        Line = 123,
                        erlroute:pub(Module, Process, 123, Topic, Msg),
                        timer:sleep(5),
                        ?assertEqual(2, ets:info('$erlroute_topics', size)),
                        MS = [{
                                #topics{
                                    topic = Topic, 
                                    words = [<<"testtopic">>],
                                    module = Module,
                                    process = Process,
                                    line = Line
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count('$erlroute_topics', MS))
                    end},
                {<<"When we pub message to same topic, we do not add anything">>, 
                    fun() ->
                        % source 
                        Module = mlibs:random_atom(),
                        Topic = <<"testtopic">>,
                        Process = self(),
                        Msg = make_ref(),
                        Line = 123,
                        erlroute:pub(Module, Process, 123, Topic, Msg),
                        timer:sleep(5),
                        ?assertEqual(3, ets:info('$erlroute_topics', size)),
                        MS = [{
                                #topics{
                                    topic = Topic, 
                                    words = [<<"testtopic">>],
                                    module = Module,
                                    process = Process,
                                    line = Line
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count('$erlroute_topics', MS)),
                        erlroute:pub(Module, Process, 123, Topic, Msg),
                        timer:sleep(5),
                        ?assertEqual(1, ets:select_count('$erlroute_topics', MS))
                    end},
                {<<"When we pub message from another module, we must have 2 entry for topic and one if match by full">>, 
                    fun() ->
                        % source 
                        Module = mlibs:random_atom(),
                        Topic = <<"testtopic2">>,
                        Process = self(),
                        Msg = make_ref(),
                        Line = 123,
                        erlroute:pub(Module, Process, 123, Topic, Msg),
                        timer:sleep(5),
                        ?assertEqual(4, ets:info('$erlroute_topics', size)),
                        MS1 = [{
                                #topics{
                                    topic = Topic, 
                                    words = [<<"testtopic2">>],
                                    process = Process,
                                    line = Line,
                                    _ = '_'
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count('$erlroute_topics', MS1)),
                        Module2 = mlibs:random_atom(),

                        erlroute:pub(Module2, Process, 123, Topic, Msg),
                        timer:sleep(5),
                        ?assertEqual(2, ets:select_count('$erlroute_topics', MS1)),
                        MSFull = [{
                                #topics{
                                    topic = Topic, 
                                    module = Module,
                                    words = [<<"testtopic2">>],
                                    process = Process,
                                    line = Line
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count('$erlroute_topics', MSFull))

                    end}
            ]
        }
    }.


erlroute_simple_defined_module_full_topic_messaging_test_() ->
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
                        Method = info,
 
                        EtsTable = erlroute:generate_routing_name(Module),
                        erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                        MS = [{
                                #active_route{
                                    topic = Topic, 
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    is_final_topic = true,
                                    parent_topic = undefined,
                                    words = undefined
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
                        Method = info,
 
                        EtsTable = erlroute:generate_routing_name(Module),
                        erlroute:sub([{topic, Topic}, {module, Module}], {DestType, Dest, Method}),
                        MS = [{
                                #active_route{
                                    topic = Topic, 
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    is_final_topic = true,
                                    parent_topic = undefined,
                                    words = undefined
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
                        Method = info,
 
                        EtsTable = erlroute:generate_routing_name(Module),
                        erlroute:sub([{topic, Topic}, {module, Module}], {DestType, Dest, Method}),
                        timer:sleep(5),
                        MS = [{
                                #active_route{
                                    topic = Topic, 
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    is_final_topic = true,
                                    parent_topic = undefined,
                                    words = undefined
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
                        Method = info,
 
                        EtsTable = erlroute:generate_routing_name(Module),
                        erlroute:sub([{module, Module}], {DestType, Dest, Method}),
                        timer:sleep(5),
                        MS = [{
                                #active_route{
                                    topic = Topic, 
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    is_final_topic = true,
                                    parent_topic = undefined,
                                    words = undefined
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
                         Method = info,
                
                         EtsTable = erlroute:generate_routing_name(Module),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         timer:sleep(5),
                         MS = [{
                                 #active_route{
                                     topic = Topic, 
                                     dest_type = DestType,
                                     dest = Dest,
                                     method = Method,
                                     is_final_topic = true,
                                     parent_topic = undefined,
                                     words = undefined
                                 },
                                 [],
                                 [true]
                             }],
                         ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/2 with full parameters and topic <<\"testtopic.*.test1.test3\">>, ets tables must present and route entry must present in ets">>, 
                    fun() ->
                        % source 
                        Module = mlibs:random_atom(),
                        Topic = <<"testtopic.*.test1.test3">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:generate_routing_name(Module),
                        erlroute:sub([{topic, Topic}, {module, Module}], {DestType, Dest, Method}),
                        timer:sleep(5),
                        MS = [{
                                #active_route{
                                    topic = Topic, 
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    is_final_topic = false,
                                    parent_topic = 'undefined',
                                    words = [<<"testtopic">>,<<"*">>,<<"test1">>,<<"test3">>]
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},
                {<<"Erlroute able to deliver message to single subscriber with exactly the same topic">>,
                    fun() ->
                        % source 
                        Module = mlibs:random_atom(),
                        SendTopic = <<"testtopic">>,
                        SubTopic = <<"testtopic">>,
                        % dest
                        DestType = process,
                        Dest = tutils:spawn_wait_loop(self()),
                        Method = info,
                
                        erlroute:sub([{module, Module}, {topic, SubTopic}], {DestType, Dest, Method}),
                        Msg = make_ref(),
                        timer:sleep(5),
                        erlroute:pub(Module, self(), ?LINE, SendTopic, Msg),
                        Ack = tutils:recieve_loop(),
                        ?assertEqual([Msg], Ack),
                        Dest ! stop
                end},

                {<<"Erlroute able to deliver message to single subscriber who subscribe to wilcard topic">>,
                    fun() ->
                        % source 
                        Module = mlibs:random_atom(),
                        SendTopic = <<"testtopic">>,
                        SubTopic = <<"*">>,
                        % dest
                        DestType = process,
                        Dest = tutils:spawn_wait_loop(self()),
                        Method = info,
                
                        erlroute:sub([{module, Module}, {topic, SubTopic}], {DestType, Dest, Method}),
                        Msg = make_ref(),
                        timer:sleep(5),
                        erlroute:pub(Module, self(), ?LINE, SendTopic, Msg),
                        Ack = tutils:recieve_loop(),
                        ?assertEqual([Msg], Ack),
                        Dest ! stop
                end},

                {<<"Erlroute able to deliver multiple message with different topic to single subscriber who subscribe to wilcard topic from same module">>,
                    fun() ->
                        % source 
                        Module = mlibs:random_atom(),
                        SendTopic1 = <<"testtopic1">>,
                        SendTopic2 = <<"testtopic2">>,
                        SubTopic = <<"*">>,
                        % dest
                        DestType = process,
                        Dest = tutils:spawn_wait_loop(self()),
                        Method = info,
                
                        erlroute:sub([{module, Module}, {topic, SubTopic}], {DestType, Dest, Method}),
                        Msg1 = make_ref(),
                        Msg2 = make_ref(),
                        timer:sleep(5),
                        erlroute:pub(Module, self(), ?LINE, SendTopic1, Msg1),
                        erlroute:pub(Module, self(), ?LINE, SendTopic2, Msg2),
                        Ack = tutils:recieve_loop(),
                        ?assertEqual([Msg2, Msg1], Ack),
                        Dest ! stop
                end},
                {<<"Messages from another module should do not delivered to another module subscribers">>,
                    fun() ->
                        % source 
                        Module1 = mlibs:random_atom(),
                        Module2 = mlibs:random_atom(),
                        SendTopic1 = <<"testtopic1">>,
                        SendTopic2 = <<"testtopic2">>,
                        SendTopic3 = <<"testtopic3">>,
                        SubTopic = <<"*">>,
                        % dest
                        DestType = process,
                        Dest = tutils:spawn_wait_loop(self()),
                        Method = info,
                
                        erlroute:sub([{module, Module1}, {topic, SubTopic}], {DestType, Dest, Method}),
                        Msg1 = make_ref(),
                        Msg2 = make_ref(),
                        Msg3 = make_ref(),

                        timer:sleep(5),
                        erlroute:pub(Module1, self(), ?LINE, SendTopic1, Msg1),
                        erlroute:pub(Module1, self(), ?LINE, SendTopic2, Msg2),
                        erlroute:pub(Module2, self(), ?LINE, SendTopic3, Msg3),
                        Ack = tutils:recieve_loop(),
                        ?assertEqual([Msg2, Msg1], Ack),
                        Dest ! stop
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
%                   end}
%
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

split_topic_key_test() ->
    ?assertEqual([<<"*">>], erlroute:split_topic_key(<<"*">>)),
    ?assertEqual([<<"test1">>,<<"test2">>], erlroute:split_topic_key(<<"test1.test2">>)),
    ?assertEqual([<<"test1">>,<<"!">>,<<"test2">>], erlroute:split_topic_key(<<"test1.!.test2">>)),
    ?assertEqual([<<"test1">>,<<"*">>,<<"test2">>], erlroute:split_topic_key(<<"test1.*.test2">>)).

setup_start() -> 
    disable_output(),
    start_server().

disable_output() ->
    error_logger:tty(false).

cleanup() -> cleanup(true).

cleanup(_) -> 
    application:stop(erlroute),
    ok.

start_server() -> application:ensure_started(?TESTSERVER).
