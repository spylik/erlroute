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
                 {<<"When erlroute doesn't start, ets-table '$erlroute_subscribers' must be undefined">>,
                    fun() ->
                        ?assertEqual(
                            undefined,
                            ets:info('$erlroute_subscribers')
                        )
                    end},
                {<<"When erlroute doesn't start, process erlroute must be unregistered">>,
                    fun() ->
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                    end},

                {<<"cache_table must generate correct ets table name when Type is by_module_name">>,
                    fun() ->
                        Source = test_producer,
                        ?assertEqual(
                            erlroute:cache_table(Source),
                            '$erlroute_cache_test_producer'
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
                {<<"When erlroute start, ets-table '$erlroute_subscribers' must be present">>,
                    fun() ->
                        ?assertNotEqual(
                            undefined,
                            ets:info('$erlroute_subscribers')
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
                        Module = tutils:random_atom(),
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
                        Module = tutils:random_atom(),
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
                        Module = tutils:random_atom(),
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
                        Module = tutils:random_atom(),
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
                        Module = tutils:random_atom(),
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
                        Module = tutils:random_atom(),
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
                        Module2 = tutils:random_atom(),

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
                        Module = tutils:random_atom(),
                        Topic = <<"#">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:cache_table(Module),
                        erlroute:sub(Module),
                        MS = [{
                                #cached_route{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
                        erlroute:unsub(Module),
                        ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/1 with binary as parameter erlroute must subscribed to all modules, specified topic (simple topic)">>,
                    fun() ->
                        % source
                        Topic = <<"testtopic">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = '$erlroute_subscribers',
                        erlroute:sub(Topic),
                        MS = [{
                                #subscriber{
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
                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
                        erlroute:unsub(Topic),
                        ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/1 with binary as parameter erlroute must subscribed to all modules, specified topic (topic with parameters)">>,
                    fun() ->
                        % source
                        Topic = <<"testtopic0.#.testtopic1">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = '$erlroute_subscribers',
                        erlroute:sub(Topic),
                        MS = [{
                                #subscriber{
                                    topic = Topic,
                                    is_final_topic = false,
                                    words = ["testtopic0","#","testtopic1"],
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    sub_ref = '_'
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
                        erlroute:unsub(Topic),
                        ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/1 with list as parameter erlroute must subscribed to right topic and module (module+topic)">>,
                    fun() ->
                        % source
                        Module = tutils:random_atom(),
                        Topic = <<"testtopic">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:cache_table(Module),
                        erlroute:sub([{module, Module},{topic, Topic}]),
                        MS = [{
                                #cached_route{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
                        erlroute:unsub([{module, Module},{topic, Topic}]),
                        ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/1 with list as parameter erlroute must subscribed to right topic and module (module only)">>,
                    fun() ->
                        % source
                        Module = tutils:random_atom(),
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:cache_table(Module),
                        erlroute:sub([{module, Module}]),
                        MS = [{
                                #cached_route{
                                    topic = <<"#">>,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
                        erlroute:unsub([{module, Module}]),
                        ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/1 with list as parameter erlroute must subscribed to right topic and module (topic only)">>,
                    fun() ->
                        % source
                        Topic = <<"test.topic">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = '$erlroute_subscribers',
                        erlroute:sub([{topic, Topic}]),
                        MS = [{
                                #subscriber{
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
                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
                        erlroute:unsub([{topic, Topic}]),
                        ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/2 when Source is complete and dest is pid() whould subscribe as {process, Pid, info}">>,
                    fun() ->
                        % source
                        Module = tutils:random_atom(),
                        Topic = <<"#">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:cache_table(Module),
                        erlroute:sub([{module, Module}, {topic, Topic}], Dest),
                        MS = [{
                                #cached_route{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
                        erlroute:unsub([{module, Module}, {topic, Topic}], Dest),
                        ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/2 when Source is atom and dest is complete should subscribe to module">>,
                    fun() ->
                        % source
                        Module = tutils:random_atom(),
                        Topic = <<"#">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:cache_table(Module),
                        erlroute:sub(Module, {DestType, Dest, Method}),
                        MS = [{
                                #cached_route{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
                        erlroute:unsub(Module, {DestType, Dest, Method}),
                        ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/2 when Source is complete and dest is atom() whould subscribe as {process, Atom, info}">>,
                    fun() ->
                        % source
                        Module = tutils:random_atom(),
                        Topic = <<"#">>,
                        % dest
                        DestType = process,
                        Dest = testregisteredprocess,
                        Method = info,

                        EtsTable = erlroute:cache_table(Module),
                        erlroute:sub([{module, Module}, {topic, Topic}], Dest),
                        MS = [{
                                #cached_route{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
                        erlroute:unsub([{module, Module}, {topic, Topic}], Dest),
                        ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/2 when Source is binary and dest is complete should subscribe globally to topic">>,
                    fun() ->
                        % source
                        Topic = <<"testtopic1.testtopic2">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = '$erlroute_subscribers',
                        erlroute:sub(Topic, {DestType, Dest, Method}),
                        MS = [{
                                #subscriber{
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
                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
                        erlroute:unsub(Topic, {DestType, Dest, Method}),
                        ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/2 with full parameters and topic <<\"#\">>, ets tables must present and route entry must present in ets">>,
                    fun() ->
                        % source
                        Module = tutils:random_atom(),
                        Topic = <<"#">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:cache_table(Module),
                        erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                        MS = [{
                                #cached_route{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
                        erlroute:unsub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                        ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/2 with full parameters and topic <<\"#\">> (reversed), ets tables must present and route entry must present in ets">>,
                    fun() ->
                        % source
                        Module = tutils:random_atom(),
                        Topic = <<"#">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:cache_table(Module),
                        erlroute:sub([{topic, Topic}, {module, Module}], {DestType, Dest, Method}),
                        MS = [{
                                #cached_route{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
                        erlroute:unsub([{topic, Topic}, {module, Module}], {DestType, Dest, Method}),
                        ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},

                {<<"After sub/2 with full parameters and topic <<\"#\">> (reversed), ets tables must present and route entry must present in ets">>,
                    fun() ->
                        % source
                        Module = tutils:random_atom(),
                        Topic = <<"#">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:cache_table(Module),
                        erlroute:sub([{topic, Topic}, {module, Module}], {DestType, Dest, Method}),
                        timer:sleep(5),
                        MS = [{
                                #cached_route{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
                        erlroute:unsub([{topic, Topic}, {module, Module}], {DestType, Dest, Method}),
                        ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},

                {<<"After sub/2 without topic it should subscribe to <<\"#\">>">>,
                    fun() ->
                        % source
                        Module = tutils:random_atom(),
                        Topic = <<"#">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        EtsTable = erlroute:cache_table(Module),
                        erlroute:sub([{module, Module}], {DestType, Dest, Method}),
                        timer:sleep(5),
                        MS = [{
                                #cached_route{
                                    topic = Topic,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    parent_topic = undefined
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count(EtsTable, MS)),
                        erlroute:unsub([{module, Module}], {DestType, Dest, Method}),
                        ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},

                {<<"After multiple sync sub/6 attempts, ets tables must have only one route entry for each type/source">>,
                    fun() ->
                         % source
                         Module = tutils:random_atom(),
                         Topic = <<"#">>,
                         % dest
                         DestType = process,
                         Dest = self(),
                         Method = info,

                         EtsTable = erlroute:cache_table(Module),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         erlroute:sub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         timer:sleep(5),
                         MS = [{
                                 #cached_route{
                                     topic = Topic,
                                     dest_type = DestType,
                                     dest = Dest,
                                     method = Method,
                                     parent_topic = undefined
                                 },
                                 [],
                                 [true]
                             }],
                         ?assertEqual(1, ets:select_count(EtsTable, MS)),
                         erlroute:unsub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         ?assertEqual(0, ets:select_count(EtsTable, MS)),
                         erlroute:unsub([{module, Module}, {topic, Topic}], {DestType, Dest, Method}),
                         ?assertEqual(0, ets:select_count(EtsTable, MS))
                    end},
                {<<"After sub/2 with full parameters and topic <<\"testtopic.*.test1.test3\">>, ets tables must present and route entry must present in ets">>,
                    fun() ->
                        % source
                        Module = tutils:random_atom(),
                        Topic = <<"testtopic.*.test1.test3">>,
                        % dest
                        DestType = process,
                        Dest = self(),
                        Method = info,

                        erlroute:sub([{topic, Topic}, {module, Module}], {DestType, Dest, Method}),
                        timer:sleep(5),
                        MS = [{
                                #subscriber{
                                    topic = Topic,
                                    module = Module,
                                    dest_type = DestType,
                                    dest = Dest,
                                    method = Method,
                                    words = ["testtopic","*","test1","test3"],
                                    _ = '_'
                                },
                                [],
                                [true]
                            }],
                        ?assertEqual(1, ets:select_count('$erlroute_subscribers', MS)),
                        erlroute:unsub([{topic, Topic}, {module, Module}], {DestType, Dest, Method}),
                        ?assertEqual(0, ets:select_count('$erlroute_subscribers', MS))
                    end},
                {<<"Erlroute able to deliver message to single subscriber with exactly the same topic">>,
                    fun() ->
                        % source
                        Module = tutils:random_atom(),
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
                        Module = tutils:random_atom(),
                        SendTopic = <<"testtopic">>,
                        SubTopic = <<"#">>,
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
                        Module = tutils:random_atom(),
                        SendTopic1 = <<"testtopic1">>,
                        SendTopic2 = <<"testtopic2">>,
                        SubTopic = <<"#">>,
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
                        Module1 = tutils:random_atom(),
                        Module2 = tutils:random_atom(),
                        SendTopic1 = <<"testtopic1">>,
                        SendTopic2 = <<"testtopic2">>,
                        SendTopic3 = <<"testtopic3">>,
                        SubTopic = <<"#">>,
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
                {<<"Should have entry in ets '$erlroute_subscribers' after subscribe to specified topic globally">>,
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
                                #subscriber{
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
                        ?assertEqual(1, ets:select_count('$erlroute_subscribers', MS)),

                        % try to subscibe again (it should not create dupe)
                        erlroute:sub([{topic, Topic}], {DestType, Dest, Method}),
                        timer:sleep(5),
                        ?assertEqual(1, ets:select_count('$erlroute_subscribers', MS))
                end},
                {<<"Global subscribe to specified topic and then pub test">>,
                    fun() ->
                        % source
                        Module = tutils:random_atom(),
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
                                #subscriber{
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
                        ?assertEqual(1, ets:select_count('$erlroute_subscribers', MS)),

                        EtsName = erlroute:cache_table(Module),

                        ?assertEqual(undefined,ets:info(EtsName)),


                        [] = erlroute:pub(Module, self(), ?LINE, Topic, Msg1),
                        timer:sleep(5),

                        ?assertNotEqual(undefined,ets:info(EtsName)),
                        ?assertEqual(1, ets:info(EtsName, size)),

                        Ack = tutils:recieve_loop(),
                        ?assertEqual([Msg1], Ack),

                        [{Dest, info}] = erlroute:pub(Module, self(), ?LINE, Topic, Msg1),
                        timer:sleep(5),

                        ?assertEqual(1, ets:info(EtsName, size)),

                        Ack2 = tutils:recieve_loop(),
                        ?assertEqual([Msg1], Ack2),

                        Dest ! stop
                    end},
                {<<"Global subscribe should cache existed topics (first pub then sub)">>,
                    fun() ->
                        % source
                        Module = tutils:random_atom(),
                        Topic = atom_to_binary(Module,latin1),
                        % dest
                        DestType = process,
                        Self = self(),
                        Dest = tutils:spawn_wait_loop(Self),
                        Method = info,
                        Msg1 = make_ref(),
                        EtsName = erlroute:cache_table(Module),

                        [] = erlroute:pub(Module, self(), ?LINE, Topic, Msg1),

                        % must do not present here
                        ?assertEqual(undefined,ets:info(EtsName)),

                        erlroute:sub([{topic, Topic}], {DestType, Dest, Method}),
                        MS = [{
                                #subscriber{
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
                        ?assertEqual(1, ets:select_count('$erlroute_subscribers', MS)),

                        _ = erlroute:pub(Module, self(), ?LINE, Topic, Msg1),

                        timer:sleep(5),

                        ?assertNotEqual(undefined,ets:info(EtsName)),
                        ?assertEqual(1, ets:info(EtsName, size)),

                        Ack = tutils:recieve_loop(),
                        ?assertEqual([Msg1], Ack),

                        [{Dest, info}] = erlroute:pub(Module, self(), ?LINE, Topic, Msg1),
                        timer:sleep(5),

                        ?assertEqual(1, ets:info(EtsName, size)),

                        Ack2 = tutils:recieve_loop(),
                        ?assertEqual([Msg1], Ack2),

                        Dest ! stop
                    end}
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
    ?assertEqual(["test1","#","test2"], erlroute:split_topic(<<"test1.#.test2">>)),
    ?assertEqual(["test1","*","test2"], erlroute:split_topic(<<"test1.*.test2">>)),
    ?assertEqual(["test1","*"], erlroute:split_topic(<<"test1.*">>)),
    ?assertEqual(["*","test1"], erlroute:split_topic(<<"*.test1">>)).

%% =============================================================
%% Cross-node remote_pub via plain send.
%%
%% Verifies that a local publish reaches a subscriber on a remote
%% node via the {remote_pub, Module, Process, Line, Topic, Payload,
%% PubType, EtsName} envelope, handled by the remote `erlroute_router'
%% (which sits next to the main `erlroute' gen_server so a publish
%% burst can't starve subscribe/unsubscribe gen_server:call traffic).
%% Each publisher-side PubType drives the remote-side dispatch
%% execution. Skipped automatically when the test runner isn't
%% distributed (node() == nonode@nohost) — run with -name/-sname
%% to exercise it.
%% =============================================================
cross_node_remote_pub_test_() ->
    {timeout, 60, fun() ->
        case is_alive() of
            false -> ok;
            true  -> do_cross_node_remote_pub()
        end
    end}.

do_cross_node_remote_pub() ->
    {ok, _} = application:ensure_all_started(erlroute),
    [_, Host] = string:split(atom_to_list(node()), "@"),
    PeerName = list_to_atom("erlroute_peer_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Peer, PeerNode} = peer:start_link(#{name => PeerName, host => Host}),
    true = rpc:call(PeerNode, code, set_path, [code:get_path()]),
    {ok, _} = rpc:call(PeerNode, application, ensure_all_started, [erlroute]),

    Cleanup = fun() ->
        catch peer:stop(Peer),
        application:stop(erlroute)
    end,

    try
        %% Local erlroute must have learned about the peer (nodeup +
        %% function_exported erpc check are async).
        ok = wait_for_peer_in_erlroute_nodes(PeerNode, 3000),
        _ = sys:get_state(erlroute),

        %% Each publisher-side PubType travels in the envelope and
        %% drives the remote dispatch path. Note: pub/7 with async
        %% spawns a sync pub internally, so the envelope reaching
        %% the remote in this case carries sync — the async handler
        %% path is exercised by the direct envelope send below.
        run_remote_pub_variant(PeerNode, sync),
        run_remote_pub_variant(PeerNode, hybrid),
        run_remote_pub_variant(PeerNode, async),

        %% Hand-crafted async envelope: ensures the remote handle_info
        %% clause accepts and dispatches PubType = async.
        assert_remote_handler_accepts_async_envelope(PeerNode),

        %% {process, Name, cast} subscriber should route as
        %% process_on_other_node + cast — direct dist send to the
        %% matcher's mailbox, bypassing remote erlroute entirely.
        run_remote_pub_variant_process_cast(PeerNode)
    catch
        Class:Reason:ST ->
            Cleanup(),
            erlang:raise(Class, Reason, ST)
    end,
    Cleanup(),
    ok.

run_remote_pub_variant(PeerNode, PubType) ->
    Topic   = list_to_binary("erlroute.crossnode.remote_pub." ++ atom_to_list(PubType)),
    Payload = {hello_from_local, PubType, erlang:unique_integer([positive])},
    Self    = self(),

    %% Subscriber lives on the peer; forwards anything it receives
    %% back across the dist link so the test can assert delivery.
    Forwarder = spawn(PeerNode,
        fun() ->
            erlroute:sub(Topic, {process, self(), info}),
            Self ! {subscribed, PubType},
            receive Msg -> Self ! {peer_received, PubType, Msg}
            after 10000 -> ok
            end
        end),

    %% Peer's sub call returns only after its erpc:multicall to us
    %% completes, so when we see {subscribed, _} the subscribe_from_remote
    %% is already in our mailbox.
    receive
        {subscribed, PubType} -> ok
    after 3000 ->
        catch exit(Forwarder, kill),
        ?assertEqual({subscribed, PubType}, timeout)
    end,

    %% sys:get_state flushes our erlroute mailbox so the local cache
    %% has the cross-node subscriber registered before we publish.
    _ = sys:get_state(erlroute),

    EtsName = erlroute:cache_table(?MODULE),
    erlroute:pub(?MODULE, self(), ?LINE, Topic, Payload, PubType, EtsName),

    receive
        {peer_received, PubType, Payload} -> ok
    after 5000 ->
        catch exit(Forwarder, kill),
        ?assertEqual({peer_received, PubType, Payload}, timeout)
    end.

%% Subscriber on the peer registers itself under a name and subscribes
%% with {process, Name, cast}. The producer-side route must be
%% process_on_other_node + cast; the published payload must arrive at
%% the matcher wrapped in {'$gen_cast', _} (the gen_server cast
%% envelope), proving the bypass path was taken.
run_remote_pub_variant_process_cast(PeerNode) ->
    Topic   = <<"erlroute.crossnode.remote_pub.process_cast">>,
    Payload = {hello_cast, erlang:unique_integer([positive])},
    Self    = self(),
    RegName = list_to_atom("erlroute_test_matcher_" ++
                           integer_to_list(erlang:unique_integer([positive]))),

    Forwarder = spawn(PeerNode,
        fun() ->
            true = register(RegName, self()),
            erlroute:sub(Topic, {process, RegName, cast}),
            Self ! cast_subscribed,
            receive Msg -> Self ! {peer_cast_received, Msg}
            after 10000 -> ok
            end
        end),

    receive cast_subscribed -> ok
    after 3000 ->
        catch exit(Forwarder, kill),
        erlang:error(cast_subscribed_timeout)
    end,

    _ = sys:get_state(erlroute),

    %% Producer-side route must be the bypass shape — not erlroute_on_other_node.
    BypassMS = [{#subscriber{topic = Topic,
                             dest_type = process_on_other_node,
                             dest = {PeerNode, RegName},
                             method = cast,
                             _ = '_'},
                 [], [true]}],
    ?assertEqual(1, ets:select_count('$erlroute_subscribers', BypassMS)),
    RouterMS = [{#subscriber{topic = Topic,
                             dest_type = erlroute_on_other_node,
                             _ = '_'},
                 [], [true]}],
    ?assertEqual(0, ets:select_count('$erlroute_subscribers', RouterMS)),

    EtsName = erlroute:cache_table(?MODULE),
    erlroute:pub(?MODULE, self(), ?LINE, Topic, Payload, hybrid, EtsName),

    receive
        {peer_cast_received, {'$gen_cast', Payload}} -> ok
    after 5000 ->
        catch exit(Forwarder, kill),
        ?assertEqual({peer_cast_received, {'$gen_cast', Payload}}, timeout)
    end.

assert_remote_handler_accepts_async_envelope(PeerNode) ->
    Topic   = <<"erlroute.crossnode.remote_pub.async_envelope">>,
    Payload = {async_envelope, erlang:unique_integer([positive])},
    Self    = self(),

    Forwarder = spawn(PeerNode,
        fun() ->
            erlroute:sub(Topic, {process, self(), info}),
            Self ! envelope_subscribed,
            receive Msg -> Self ! {peer_dispatched_async, Msg}
            after 10000 -> ok
            end
        end),

    receive envelope_subscribed -> ok
    after 3000 ->
        catch exit(Forwarder, kill),
        erlang:error(envelope_subscribed_timeout)
    end,

    EtsName = erlroute:cache_table(?MODULE),
    erlang:send({erlroute_router, PeerNode},
                {remote_pub, ?MODULE, self(), ?LINE, Topic, Payload, async, EtsName}),

    receive
        {peer_dispatched_async, Payload} -> ok
    after 5000 ->
        catch exit(Forwarder, kill),
        ?assertEqual({peer_dispatched_async, Payload}, timeout)
    end.

wait_for_peer_in_erlroute_nodes(PeerNode, Timeout) when Timeout =< 0 ->
    ?assertEqual({peer_known_to_local_erlroute, PeerNode}, timeout);
wait_for_peer_in_erlroute_nodes(PeerNode, Timeout) ->
    #erlroute_state{erlroute_nodes = Nodes} = sys:get_state(erlroute),
    case lists:member(PeerNode, Nodes) of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_for_peer_in_erlroute_nodes(PeerNode, Timeout - 50)
    end.

setup_start() ->
    start_server().

disable_output() ->
    error_logger:tty(false).

cleanup() -> cleanup(true).

cleanup(_) ->
    application:stop(erlroute),
    ok.

start_server() -> application:ensure_started(?TESTSERVER).
