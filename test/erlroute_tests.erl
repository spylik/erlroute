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
                        ?assertEqual(ok, ?TESTSERVER:stop(sync)),
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"Application able to start and stop via ?TESTSERVER:start_link() / ?TESTSERVER:stop(sync)">>,
                    fun() ->
                        ?TESTSERVER:start_link(),
                        ?assertEqual(ok, ?TESTSERVER:stop(sync)),
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"Application able to start and stop via ?TESTSERVER:start_link() / ?TESTSERVER:stop()">>,
                    fun() ->
                        ?TESTSERVER:start_link(),
                        ?assertEqual(ok, ?TESTSERVER:stop()),
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
                 {<<"When erlroute doesn't start, ets-table '$erlroute_global_sub' must be undefined">>,
                    fun() ->
                        ?assertEqual(
                            undefined,
                            ets:info('$erlroute_global_sub')
                        )
                    end},
                {<<"When erlroute doesn't start, process erlroute must be unregistered">>,
                    fun() ->
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                    end},

                {<<"generate_complete_routing_name must generate correct ets table name when Type is by_module_name">>,
                    fun() ->
                        Source = test_producer,
                        ?assertEqual(
                            erlroute:generate_complete_routing_name(Source),
                            '$erlroute_cmp_test_producer'
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
                },
                {<<"When erlroute start, ets-table '$erlroute_global_sub' must be present">>,
                    fun() ->
                        ?assertNotEqual(
                            undefined,
                            ets:info('$erlroute_global_sub')
                        )
                    end
                }

            ]
        }
    }.

% test pub_routine
erlroute_inorder_test_() ->
    {setup,
        fun setup_start/0,
        fun cleanup/1,
        {inorder,
            [
                {<<"After pub/5 we must have one record in topics ets">>,
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
                {<<"After full_async_pub we must have two record in topics ets">>,
                    fun() ->
                        % source
                        ?assertEqual(1, ets:info('$erlroute_topics', size)),
                        Module = mlibs:random_atom(),
                        SendTopic = <<"testtopic">>,
                        Process = self(),
                        Msg = make_ref(),
                        erlroute:full_async_pub(Module, Process, ?LINE, SendTopic, Msg),
                        timer:sleep(5),
                        ?assertEqual(2, ets:info('$erlroute_topics', size))
                    end},
                {<<"After full_sync_pub we must have three record in topics ets">>,
                    fun() ->
                        % source
                        ?assertEqual(2, ets:info('$erlroute_topics', size)),
                        Module = mlibs:random_atom(),
                        SendTopic = <<"testtopic">>,
                        Process = self(),
                        Msg = make_ref(),
                        erlroute:full_sync_pub(Module, Process, ?LINE, SendTopic, Msg),
                        timer:sleep(5),
                        ?assertEqual(3, ets:info('$erlroute_topics', size))
                    end},
                {<<"After pub we must have for record and one record in topics ets with right data">>,
                    fun() ->
                        % source
                        Module = mlibs:random_atom(),
                        Topic = <<"testtopic">>,
                        Process = self(),
                        Msg = make_ref(),
                        Line = 123,
                        erlroute:pub(Module, Process, 123, Topic, Msg),
                        timer:sleep(5),
                        ?assertEqual(4, ets:info('$erlroute_topics', size)),
                        MS = [{
                                #topics{
                                    topic = Topic,
                                    words = ["testtopic"],
                                    module = Module,
                                    process = '_',
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
                        ?assertEqual(4, ets:info('$erlroute_topics', size)),
                        erlroute:pub(Module, Process, 123, Topic, Msg),
                        timer:sleep(5),
                        ?assertEqual(5, ets:info('$erlroute_topics', size)),
                        MS = [{
                                #topics{
                                    topic = Topic,
                                    words = ["testtopic"],
                                    module = Module,
                                    process = '_',
                                    line = Line
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count('$erlroute_topics', MS)),
                        erlroute:pub(Module, Process, 123, Topic, Msg),
                        timer:sleep(5),
                        ?assertEqual(5, ets:info('$erlroute_topics', size)),
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
                        ?assertEqual(6, ets:info('$erlroute_topics', size)),
                        MS1 = [{
                                #topics{
                                    topic = Topic,
                                    words = ["testtopic2"],
                                    process = '_',
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
                                    words = ["testtopic2"],
                                    process = '_',
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
                {<<"After sub/1 with atom as parameter erlroute must subscribed to module output">>,
                    fun() ->
                        % source
                        Module = mlibs:random_atom(),
                        Topic = <<"*">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:generate_complete_routing_name(Module),
                        erlroute:sub(Module),
                        MS = [{
                                #complete_routes{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/1 with binary as parameter erlroute must subscribed to all modules, specified topic (simple topic)">>,
                    fun() ->
                        % source
                        Topic = <<"testtopic">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = '$erlroute_global_sub',
                        erlroute:sub(Topic),
                        MS = [{
                                #subscribers_by_topic_only{
                                    topic = Topic,
                                    is_final_topic = true,
                                    words = undefined,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    sub_ref = '_'
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/1 with binary as parameter erlroute must subscribed to all modules, specified topic (topic with parameters)">>,
                    fun() ->
                        % source
                        Topic = <<"testtopic0.!.testtopic1">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = '$erlroute_global_sub',
                        erlroute:sub(Topic),
                        MS = [{
                                #subscribers_by_topic_only{
                                    topic = Topic,
                                    is_final_topic = false,
                                    words = ["testtopic0","!","testtopic1"],
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    sub_ref = '_'
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/1 with list as parameter erlroute must subscribed to right topic and module (module+topic)">>,
                    fun() ->
                        % source
                        Module = mlibs:random_atom(),
                        Topic = <<"testtopic">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:generate_complete_routing_name(Module),
                        erlroute:sub([{module, Module},{topic, Topic}]),
                        MS = [{
                                #complete_routes{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/1 with list as parameter erlroute must subscribed to right topic and module (module only)">>,
                    fun() ->
                        % source
                        Module = mlibs:random_atom(),
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:generate_complete_routing_name(Module),
                        erlroute:sub([{module, Module}]),
                        MS = [{
                                #complete_routes{
                                    topic = <<"*">>,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/1 with list as parameter erlroute must subscribed to right topic and module (topic only)">>,
                    fun() ->
                        % source
                        Topic = <<"test.topic">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = '$erlroute_global_sub',
                        erlroute:sub([{topic, Topic}]),
                        MS = [{
                                #subscribers_by_topic_only{
                                    topic = Topic,
                                    is_final_topic = true,
                                    words = undefined,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    sub_ref = '_'
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/2 when Source is complete and dest is pid() whould subscribe as {process, Pid, info}">>,
                    fun() ->
                        % source
                        Module = mlibs:random_atom(),
                        Topic = <<"*">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:generate_complete_routing_name(Module),
                        erlroute:sub([{module, Module}, {topic, Topic}], Dest),
                        MS = [{
                                #complete_routes{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/2 when Source is complete and dest is atom() whould subscribe as {process, Atom, info}">>,
                    fun() ->
                        % source
                        Module = mlibs:random_atom(),
                        Topic = <<"*">>,
                        % dest
                        DestType = process,
                        Dest = testregisteredprocess,
                        Method = info,

                        EtsTable = erlroute:generate_complete_routing_name(Module),
                        erlroute:sub([{module, Module}, {topic, Topic}], Dest),
                        MS = [{
                                #complete_routes{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/2 when Source is atom and dest is complete should subscribe to module">>,
                    fun() ->
                        % source
                        Module = mlibs:random_atom(),
                        Topic = <<"*">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:generate_complete_routing_name(Module),
                        erlroute:sub(Module, {DestType, Dest, Method}),
                        MS = [{
                                #complete_routes{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/2 when Source is binary and dest is complete should subscribe globally to topic">>,
                    fun() ->
                        % source
                        Topic = <<"testtopic1.testtopic2">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = '$erlroute_global_sub',
                        erlroute:sub(Topic, {DestType, Dest, Method}),
                        MS = [{
                                #subscribers_by_topic_only{
                                    topic = Topic,
                                    is_final_topic = true,
                                    words = undefined,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    sub_ref = '_'
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/2 with full parameters and topic <<\"*\">>, ets tables must present and route entry must present in ets">>,
                    fun() ->
                        % source
                        Module = mlibs:random_atom(),
                        Topic = <<"*">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:generate_complete_routing_name(Module),
                        erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                        MS = [{
                                #complete_routes{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
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

                        EtsTable = erlroute:generate_complete_routing_name(Module),
                        erlroute:sub([{topic, Topic}, {module, Module}], {DestType, Dest, Method}),
                        MS = [{
                                #complete_routes{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
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

                        EtsTable = erlroute:generate_complete_routing_name(Module),
                        erlroute:sub([{topic, Topic}, {module, Module}], {DestType, Dest, Method}),
                        timer:sleep(5),
                        MS = [{
                                #complete_routes{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
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

                        EtsTable = erlroute:generate_complete_routing_name(Module),
                        erlroute:sub([{module, Module}], {DestType, Dest, Method}),
                        timer:sleep(5),
                        MS = [{
                                #complete_routes{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
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

                         EtsTable = erlroute:generate_complete_routing_name(Module),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         timer:sleep(5),
                         MS = [{
                                 #complete_routes{
                                     topic = Topic,
                                     dest_type = DestType,
                                     dest = Dest,
                                     method = Method,
                                     parent_topic = undefined
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

                        EtsTable = erlroute:generate_parametrized_routing_name(Module),
                        erlroute:sub([{topic, Topic}, {module, Module}], {DestType, Dest, Method}),
                        timer:sleep(5),
                        MS = [{
                                #parametrize_routes{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    words = ["testtopic","*","test1","test3"]
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
                        ?assertEqual(lists:sort([Msg1, Msg2]), lists:sort(Ack)),
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
                        ?assertEqual(lists:sort([Msg1,Msg2]), lists:sort(Ack)),
                        Dest ! stop
                end},
                {<<"Should have entry in ets '$erlroute_global_sub' after subscribe to specified topic globally">>,
                    fun() ->
                        % source
                        Topic = <<"testmegatopic">>,
                        % dest
                        DestType = process,
                        Dest = tutils:spawn_wait_loop(self()),
                        Method = info,

                        erlroute:sub([{topic, Topic}], {DestType, Dest, Method}),
                        timer:sleep(5),
                        MS = [{
                                #subscribers_by_topic_only{
                                    topic = Topic,
                                    is_final_topic = true,
                                    words = 'undefined',
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    sub_ref = '_'
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count('$erlroute_global_sub', MS))
                end},
                {<<"Global subscribe to specified topic and then pub test">>,
                    fun() ->
                        % source
                        Module = mlibs:random_atom(),
                        Topic = atom_to_binary(Module,latin1),
                        % dest
                        DestType = process,
                        Self = self(),
                        Dest = tutils:spawn_wait_loop(Self),
                        Method = info,

                        Msg1 = make_ref(),

                        erlroute:sub([{topic, Topic}], {DestType, Dest, Method}),
                        timer:sleep(5),
                        MS = [{
                                #subscribers_by_topic_only{
                                    topic = Topic,
                                    is_final_topic = true,
                                    words = 'undefined',
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    sub_ref = '_'
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count('$erlroute_global_sub', MS)),

                        EtsName = erlroute:generate_complete_routing_name(Module),

                        ?assertEqual(undefined,ets:info(EtsName)),


                        [] = erlroute:pub(Module, self(), ?LINE, Topic, Msg1),
                        timer:sleep(5),

                        ?assertNotEqual(undefined,ets:info(EtsName)),
                        ?assertEqual(1, ets:info(EtsName, size)),

                        Ack = tutils:recieve_loop(),
                        ?assertEqual([Msg1], Ack),

                        [Dest] = erlroute:pub(Module, self(), ?LINE, Topic, Msg1),
                        timer:sleep(5),

                        ?assertEqual(1, ets:info(EtsName, size)),

                        Ack2 = tutils:recieve_loop(),
                        ?assertEqual([Msg1], Ack2),

                        Dest ! stop
                    end},
                {<<"Global subscribe should cache existed topics (first pub then sub)">>,
                    fun() ->
                        % source
                        Module = mlibs:random_atom(),
                        Topic = atom_to_binary(Module,latin1),
                        % dest
                        DestType = process,
                        Self = self(),
                        Dest = tutils:spawn_wait_loop(Self),
                        Method = info,
                        Msg1 = make_ref(),
                        EtsName = erlroute:generate_complete_routing_name(Module),

                        [] = erlroute:pub(Module, self(), ?LINE, Topic, Msg1),

                        % must do not present here
                        ?assertEqual(undefined,ets:info(EtsName)),

                        erlroute:sub([{topic, Topic}], {DestType, Dest, Method}),
                        timer:sleep(5),
                        MS = [{
                                #subscribers_by_topic_only{
                                    topic = Topic,
                                    is_final_topic = true,
                                    words = 'undefined',
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    sub_ref = '_'
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count('$erlroute_global_sub', MS)),

                        % must present here
                        ?assertNotEqual(undefined,ets:info(EtsName)),

                        [Dest] = erlroute:pub(Module, self(), ?LINE, Topic, Msg1),
                        timer:sleep(5),

                        ?assertNotEqual(undefined,ets:info(EtsName)),
                        ?assertEqual(1, ets:info(EtsName, size)),

                        Ack = tutils:recieve_loop(),
                        ?assertEqual([Msg1], Ack),

                        [Dest] = erlroute:pub(Module, self(), ?LINE, Topic, Msg1),
                        timer:sleep(5),

                        ?assertEqual(1, ets:info(EtsName, size)),

                        Ack2 = tutils:recieve_loop(),
                        ?assertEqual([Msg1], Ack2),

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
%                        EtsTable = erlroute:generate_complete_routing_name(Type, Source),
%                        MS = [{
%                                #complete_routes{
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
%                       EtsTable = erlroute:generate_complete_routing_name(Type, Source),
%                       MS = [{
%                               #complete_routes{
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
%                       EtsTable = erlroute:generate_complete_routing_name(Type, Source),
%                       MS = [{
%                               #complete_routes{
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
%                       EtsTable = erlroute:generate_complete_routing_name(Type, Source),
%                       MS = [{
%                               #complete_routes{
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

parse_transform_test_() ->
    {setup,
        fun setup_start/0,
        {inparallel,
             [
                {<<"pub/1 should transform to pub/5 (in module clause) and consumer able to get message">>,
                    fun() ->
                        % source
                        Module = ?MODULE,
                        %SendTopic = <<"erlroute_tests.14">>,
                        SubTopic = <<"erlroute_tests.14">>,
                        % dest
                        DestType = process,
                        Dest = tutils:spawn_wait_loop(self()),
                        Method = info,

                        erlroute:sub([{module, Module}, {topic, SubTopic}], {DestType, Dest, Method}),
                        Msg = make_ref(),
                        timer:sleep(5),
                        publish(Msg),
                        Ack = tutils:recieve_loop(),
                        ?assertEqual([Msg], Ack),
                        Dest ! stop
                end},

               {<<"pub/2 should transform to pub/5 (in module clause) and consumer able to get message">>,
                   fun() ->
                        % source
                        Module = ?MODULE,
                        SendTopic = <<"erlroute_tests.15">>,
                        SubTopic = <<"erlroute_tests.15">>,
                        % dest
                        DestType = process,
                        Dest = tutils:spawn_wait_loop(self()),
                        Method = info,

                        erlroute:sub([{module, Module}, {topic, SubTopic}], {DestType, Dest, Method}),
                        Msg = make_ref(),
                        timer:sleep(5),
                        publish(SendTopic, Msg),
                        Ack = tutils:recieve_loop(),
                        ?assertEqual([Msg], Ack),
                        Dest ! stop
               end}
            ]
        }
    }.

split_topic_test() ->
    ?assertEqual(["*"], erlroute:split_topic(<<"*">>)),
    ?assertEqual(["test1","test2"], erlroute:split_topic(<<"test1.test2">>)),
    ?assertEqual(["test1","!","test2"], erlroute:split_topic(<<"test1.!.test2">>)),
    ?assertEqual(["test1","*","test2"], erlroute:split_topic(<<"test1.*.test2">>)),
    ?assertEqual(["test1","*"], erlroute:split_topic(<<"test1.*">>)),
    ?assertEqual(["*","test1"], erlroute:split_topic(<<"*.test1">>)).

setup_start() ->
    start_server().

disable_output() ->
    error_logger:tty(false).

cleanup() -> cleanup(true).

cleanup(_) ->
    application:stop(erlroute),
    ok.

start_server() -> application:ensure_started(?TESTSERVER).
