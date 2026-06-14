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

monitor_test_() ->
    {setup,
        fun setup_start/0,
        fun cleanup/1,
        {inorder, [
            {<<"duplicate subscribe for same pid creates exactly one monitor">>,
                fun() ->
                    Pid = spawn(fun() -> receive stop -> ok after 5000 -> ok end end),
                    FlowSource = #flow_source{module = tutils:random_atom(), topic = <<"#">>},
                    erlroute:sub(FlowSource, {process, Pid, info}),
                    erlroute:sub(FlowSource, {process, Pid, info}),
                    #erlroute_state{monitors = Monitors} = sys:get_state(erlroute),
                    ?assert(maps:is_key(Pid, Monitors)),
                    %% exactly one beam monitor (no leak from the duplicate sub)
                    {monitors, Mons} = process_info(self(), monitors),
                    PidMons = [P || {process, P} <- Mons, P =:= Pid],
                    ?assertEqual([], PidMons), % our test process didn't monitor it
                    {monitored_by, Watchers} = process_info(Pid, monitored_by),
                    ?assertEqual(1, length([W || W <- Watchers, W =:= whereis(erlroute)])),
                    Pid ! stop
                end},
            {<<"unsub removes monitor when no subscriptions remain">>,
                fun() ->
                    Pid = spawn(fun() -> receive stop -> ok after 5000 -> ok end end),
                    FlowSource = #flow_source{module = tutils:random_atom(), topic = <<"#">>},
                    erlroute:sub(FlowSource, {process, Pid, info}),
                    #erlroute_state{monitors = M1} = sys:get_state(erlroute),
                    ?assert(maps:is_key(Pid, M1)),
                    erlroute:unsub(FlowSource, {process, Pid, info}),
                    #erlroute_state{monitors = M2} = sys:get_state(erlroute),
                    ?assertNot(maps:is_key(Pid, M2)),
                    {monitored_by, Watchers} = process_info(Pid, monitored_by),
                    ?assertEqual([], [W || W <- Watchers, W =:= whereis(erlroute)]),
                    Pid ! stop
                end},
            {<<"unsub keeps monitor while other subscriptions for the pid remain">>,
                fun() ->
                    Pid = spawn(fun() -> receive stop -> ok after 5000 -> ok end end),
                    Module = tutils:random_atom(),
                    FS1 = #flow_source{module = Module, topic = <<"t1">>},
                    FS2 = #flow_source{module = Module, topic = <<"t2">>},
                    erlroute:sub(FS1, {process, Pid, info}),
                    erlroute:sub(FS2, {process, Pid, info}),
                    erlroute:unsub(FS1, {process, Pid, info}),
                    #erlroute_state{monitors = M1} = sys:get_state(erlroute),
                    ?assert(maps:is_key(Pid, M1)),   %% still has FS2 sub
                    erlroute:unsub(FS2, {process, Pid, info}),
                    #erlroute_state{monitors = M2} = sys:get_state(erlroute),
                    ?assertNot(maps:is_key(Pid, M2)), %% now fully removed
                    Pid ! stop
                end}
        ]}
    }.

%% Router pool: started by the app supervision tree, default size, with stable
%% per-topic assignment spread across the pool.
router_pool_test_() ->
    {setup,
        fun setup_start/0,
        fun cleanup/1,
        {inorder,
            [
                {<<"router pool starts at default size (10), all live">>,
                    fun() ->
                        ?assertEqual(10, erlroute:router_pool_size()),
                        Pool = ets:lookup_element('$erlroute_routers', '$routers', 2),
                        ?assertEqual(10, tuple_size(Pool)),
                        lists:foreach(fun(Pid) -> ?assert(is_process_alive(Pid)) end,
                                      tuple_to_list(Pool))
                    end},
                {<<"assign_router is sticky per topic and returns a pool member">>,
                    fun() ->
                        Pool = tuple_to_list(ets:lookup_element('$erlroute_routers', '$routers', 2)),
                        Topic = <<"alpha.topic">>,
                        Pid = erlroute:assign_router(Topic),
                        ?assert(is_pid(Pid)),
                        ?assertEqual(Pid, erlroute:assign_router(Topic)),   %% sticky
                        ?assert(lists:member(Pid, Pool))
                    end},
                {<<"topics are spread round-robin across more than one router">>,
                    fun() ->
                        Assigned = [erlroute:assign_router(integer_to_binary(N)) || N <- lists:seq(1, 200)],
                        ?assert(length(lists:usort(Assigned)) > 1)
                    end}
            ]
        }
    }.

cross_node_test_() ->
    {setup,
        fun setup_distribution/0,
        fun teardown_distribution/1,
        {inorder, [
            {"remote_pub via plain send",     {timeout, 60, fun do_cross_node_remote_pub/0}},
            {"multi-node, no duplicate send", {timeout, 60, fun do_cross_node_multi_node_no_dup/0}},
            {"symmetric node discovery",      {timeout, 30, fun do_cross_node_symmetric_discovery/0}},
            {"discovery/propagation settles", {timeout, 60, fun do_cross_node_discovery_settles/0}}
        ]}
    }.

do_cross_node_remote_pub() ->
    {ok, _} = application:ensure_all_started(erlroute),
    [_, Host] = string:split(atom_to_list(node()), "@"),
    {ok, Peer, PeerNode} = start_erlroute_peer(Host, "erlroute_peer"),

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

        %% Hand-crafted async envelope sent to the peer's assigned router
        %% for the topic: ensures a pool router accepts and dispatches it.
        assert_assigned_router_dispatches_envelope(PeerNode),

        %% {process, Name, cast} subscriber should route as
        %% process_on_other_node + cast — direct dist send to the
        %% matcher's mailbox, bypassing the remote router entirely.
        run_remote_pub_variant_process_cast(PeerNode),

        %% Function subscriber → erlroute_on_other_node route addressed by
        %% the peer's assigned router pid. Exercises the full pool path:
        %% assignment, pid propagation, and direct-to-router publish.
        run_remote_pub_variant_function(PeerNode),

        %% Two process subscribers on the peer for the same topic must flip
        %% the publisher to a single pool route (one network send), and both
        %% must receive exactly once.
        run_multi_process_flips_to_pool(PeerNode),

        %% A process + a function subscriber on the peer for the same topic
        %% must both be served via the single pool route, each exactly once
        %% (no double delivery to the process).
        run_mixed_process_and_function_via_pool(PeerNode)
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

%% Send a hand-crafted remote_pub envelope to the peer's *assigned* router for
%% the topic (resolved via the peer's own assign_router), and verify that pool
%% member dispatches it to a local subscriber on the peer.
assert_assigned_router_dispatches_envelope(PeerNode) ->
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

    RouterPid = rpc:call(PeerNode, erlroute, assign_router, [Topic]),
    ?assert(is_pid(RouterPid)),

    EtsName = erlroute:cache_table(?MODULE),
    erlang:send(RouterPid,
                {remote_pub, ?MODULE, self(), ?LINE, Topic, Payload, async, EtsName}),

    receive
        {peer_dispatched_async, Payload} -> ok
    after 5000 ->
        catch exit(Forwarder, kill),
        ?assertEqual({peer_dispatched_async, Payload}, timeout)
    end.

%% End-to-end pool path: a function subscriber on the peer becomes an
%% erlroute_on_other_node route on the publisher, addressed by the peer's
%% assigned router pid. Publishing locally must reach the peer's function via
%% that router.
run_remote_pub_variant_function(PeerNode) ->
    Topic   = <<"erlroute.crossnode.remote_pub.function">>,
    Payload = {hello_function, erlang:unique_integer([positive])},
    Self    = self(),

    Forwarder = spawn(PeerNode,
        fun() ->
            %% Function executes on the peer (where its router runs pub);
            %% it ships the payload back across the dist link to us.
            erlroute:sub(Topic, fun(P) -> Self ! {peer_function_received, P} end),
            Self ! function_subscribed,
            receive _ -> ok after 10000 -> ok end
        end),

    receive function_subscribed -> ok
    after 3000 ->
        catch exit(Forwarder, kill),
        erlang:error(function_subscribed_timeout)
    end,

    _ = sys:get_state(erlroute),

    %% Publisher-side route must be erlroute_on_other_node addressed by the
    %% peer's assigned router pid for this topic.
    ExpectedRouter = rpc:call(PeerNode, erlroute, assign_router, [Topic]),
    ?assert(is_pid(ExpectedRouter)),
    RouteMS = [{#subscriber{topic = Topic,
                            dest_type = erlroute_on_other_node,
                            dest = {PeerNode, ExpectedRouter},
                            _ = '_'},
                [], [true]}],
    ?assertEqual(1, ets:select_count('$erlroute_subscribers', RouteMS)),

    EtsName = erlroute:cache_table(?MODULE),
    erlroute:pub(?MODULE, self(), ?LINE, Topic, Payload, hybrid, EtsName),

    receive
        {peer_function_received, Payload} -> ok
    after 5000 ->
        catch exit(Forwarder, kill),
        ?assertEqual({peer_function_received, Payload}, timeout)
    end.

%% Spawn a peer process that subscribes itself to Topic as {process, self,
%% Method}, then reports the first message it gets plus whether a second
%% (duplicate) arrives shortly after. Returns its pid.
spawn_peer_process_subscriber(PeerNode, Topic, Method, Tag, ReportTo) ->
    spawn(PeerNode,
        fun() ->
            erlroute:sub(Topic, {process, self(), Method}),
            ReportTo ! {peer_subscribed, Tag},
            First = receive M -> M after 10000 -> none end,
            %% if direct + pool routes coexisted we'd get a duplicate here
            Extra = receive M2 -> {extra, M2} after 500 -> no_extra end,
            ReportTo ! {peer_got, Tag, First, Extra}
        end).

%% Two distinct process subscribers on the peer for one topic: the publisher
%% must collapse to a single pool route (one send over the wire), and both
%% subscribers must receive the payload exactly once.
run_multi_process_flips_to_pool(PeerNode) ->
    Topic   = <<"erlroute.crossnode.multi_process">>,
    Payload = {multi_proc, erlang:unique_integer([positive])},
    Self    = self(),

    P1 = spawn_peer_process_subscriber(PeerNode, Topic, info, p1, Self),
    receive {peer_subscribed, p1} -> ok after 3000 -> erlang:error(p1_subscribe_timeout) end,
    _ = sys:get_state(erlroute),

    P2 = spawn_peer_process_subscriber(PeerNode, Topic, info, p2, Self),
    receive {peer_subscribed, p2} -> ok after 3000 -> erlang:error(p2_subscribe_timeout) end,
    _ = sys:get_state(erlroute),

    %% Publisher-side: exactly one pool route to the peer, no direct routes.
    PoolMS = [{#subscriber{topic = Topic, dest_type = erlroute_on_other_node, dest = {PeerNode, '_'}, _ = '_'},
               [], [true]}],
    DirectMS = [{#subscriber{topic = Topic, dest_type = process_on_other_node, dest = {PeerNode, '_'}, _ = '_'},
                 [], [true]}],
    ?assertEqual(1, ets:select_count('$erlroute_subscribers', PoolMS)),
    ?assertEqual(0, ets:select_count('$erlroute_subscribers', DirectMS)),

    EtsName = erlroute:cache_table(?MODULE),
    erlroute:pub(?MODULE, self(), ?LINE, Topic, Payload, hybrid, EtsName),

    assert_peer_got_once(p1, Payload),
    assert_peer_got_once(p2, Payload),
    catch exit(P1, kill),
    catch exit(P2, kill).

%% A process subscriber and a function subscriber on the peer for one topic:
%% both served by the single pool route, each exactly once (the process must
%% not also get a direct copy).
run_mixed_process_and_function_via_pool(PeerNode) ->
    Topic   = <<"erlroute.crossnode.mixed">>,
    Payload = {mixed, erlang:unique_integer([positive])},
    Self    = self(),

    P = spawn_peer_process_subscriber(PeerNode, Topic, info, mixed_proc, Self),
    receive {peer_subscribed, mixed_proc} -> ok after 3000 -> erlang:error(mixed_proc_timeout) end,
    _ = sys:get_state(erlroute),

    F = spawn(PeerNode,
        fun() ->
            erlroute:sub(Topic, fun(Pl) -> Self ! {peer_got, mixed_fun, Pl, no_extra} end),
            Self ! {peer_subscribed, mixed_fun},
            receive _ -> ok after 10000 -> ok end
        end),
    receive {peer_subscribed, mixed_fun} -> ok after 3000 -> erlang:error(mixed_fun_timeout) end,
    _ = sys:get_state(erlroute),

    %% Mixed subscribers force the pool route; no direct route to the process.
    PoolMS = [{#subscriber{topic = Topic, dest_type = erlroute_on_other_node, dest = {PeerNode, '_'}, _ = '_'},
               [], [true]}],
    DirectMS = [{#subscriber{topic = Topic, dest_type = process_on_other_node, dest = {PeerNode, '_'}, _ = '_'},
                 [], [true]}],
    ?assertEqual(1, ets:select_count('$erlroute_subscribers', PoolMS)),
    ?assertEqual(0, ets:select_count('$erlroute_subscribers', DirectMS)),

    EtsName = erlroute:cache_table(?MODULE),
    erlroute:pub(?MODULE, self(), ?LINE, Topic, Payload, hybrid, EtsName),

    assert_peer_got_once(mixed_proc, Payload),
    assert_peer_got_once(mixed_fun, Payload),
    catch exit(P, kill),
    catch exit(F, kill).

assert_peer_got_once(Tag, Payload) ->
    receive
        {peer_got, Tag, Got, Extra} ->
            ?assertEqual(Payload, Got),
            ?assertEqual(no_extra, Extra)
    after 5000 ->
        ?assertEqual({peer_got, Tag, Payload}, timeout)
    end.

%% Multi-node (3 nodes, full mesh): one publish must reach each subscriber
%% exactly once. Guards against a node re-forwarding a remote_pub to its own
%% cross-node routes (duplicate delivery). Driven by cross_node_test_/0.
do_cross_node_multi_node_no_dup() ->
    %% Keep the controller out of the erlroute mesh: with it running, the
    %% fresh peers pull its accumulated subscriptions from earlier tests on
    %% join, which perturbs dispatch and hides the bug. A clean 3-peer mesh
    %% is the faithful reproduction.
    _ = application:stop(erlroute),
    [_, Host] = string:split(atom_to_list(node()), "@"),
    %% Three fresh peers in a full mesh; publish from one of them. (Publishing
    %% from the test/controller node hides the bug — its cache carries state
    %% from earlier tests.)
    {ok, PeerA, NodeA} = start_erlroute_peer(Host, "erlroute_mn_a"),
    {ok, PeerB, NodeB} = start_erlroute_peer(Host, "erlroute_mn_b"),
    {ok, PeerC, NodeC} = start_erlroute_peer(Host, "erlroute_mn_c"),
    StopPeers = fun() -> [catch peer:stop(P) || P <- [PeerA, PeerB, PeerC]] end,
    Cleanup = fun() -> StopPeers(), application:stop(erlroute) end,
    Nodes = [NodeA, NodeB, NodeC],
    Topic = <<"erlroute.crossnode.multi_node">>,
    Self  = self(),

    try
        ok = wait_erlroute_mesh(Nodes, 8000),

        %% Every node has one function subscriber for the topic. Each reports
        %% a tagged hit so we can count deliveries per node.
        Forwarders = [subscribe_reporter(N, Topic, Tag, Self)
                      || {N, Tag} <- [{NodeA, a}, {NodeB, b}, {NodeC, c}]],

        %% Each node should now hold a route to each of the other two.
        ok = wait_remote_route_count(Nodes, Topic, 2, 8000),

        %% Publish ONCE from a peer.
        _ = rpc:call(NodeA, erlroute, pub,
                     [?MODULE, mn_publisher, ?LINE, Topic,
                      {mn_payload, erlang:unique_integer([positive])},
                      hybrid, erlroute:cache_table(?MODULE)]),

        %% Capped: a re-forward storm trips the cap and fails the assertion
        %% instead of hanging the suite.
        Hits = collect_tagged_hits(#{}, 20),
        [catch exit(F, kill) || F <- Forwarders],
        StopPeers(),
        ?assertEqual(#{a => 1, b => 1, c => 1}, Hits)
    catch
        Class:Reason:ST ->
            Cleanup(),
            erlang:raise(Class, Reason, ST)
    end,
    Cleanup(),
    ok.

setup_distribution() ->
    case is_alive() of
        true  -> {false, false};    % runner already distributed — touch nothing
        false ->
            StartedEpmd = case epmd_running() of
                true  -> false;
                false -> _ = os:cmd("epmd -daemon"), true
            end,
            Name = list_to_atom("erlroute_ct_" ++ os:getpid()),
            {ok, _} = net_kernel:start([Name, shortnames]),
            {StartedEpmd, true}
    end.

%% Revert exactly what setup_distribution/0 started — and nothing it didn't.
teardown_distribution({StartedEpmd, StartedNetKernel}) ->
    _ = case StartedNetKernel of
        true  -> net_kernel:stop();     % back to nonode@nohost; unregisters us from epmd
        false -> ok
    end,
    _ = case StartedEpmd of
        true  -> os:cmd("epmd -kill");  % only the epmd WE spawned (refuses if live nodes remain)
        false -> ok
    end,
    ok.

%% True if a local epmd is already accepting connections (queried without
%% needing distribution to be up).
epmd_running() ->
    case net_adm:names() of
        {ok, _}    -> true;
        {error, _} -> false
    end.

start_erlroute_peer(Host, Prefix) ->
    Name = list_to_atom(Prefix ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))),
    %% Hand the peer our exact cookie so it doesn't depend on ~/.erlang.cookie
    %% matching — works whether the cookie was auto-generated by net_kernel or
    %% inherited from the runner.
    {ok, Peer, Node} = peer:start_link(#{name => Name, host => Host,
                                         args => ["-setcookie", atom_to_list(erlang:get_cookie())]}),
    true = rpc:call(Node, code, set_path, [code:get_path()]),
    {ok, _} = rpc:call(Node, application, ensure_all_started, [erlroute]),
    {ok, Peer, Node}.

subscribe_reporter(Node, Topic, Tag, ReportTo) ->
    Forwarder = spawn(Node,
        fun() ->
            erlroute:sub(Topic, fun(_P) -> ReportTo ! {mn_hit, Tag} end),
            ReportTo ! {mn_subbed, Tag},
            receive _ -> ok after 30000 -> ok end
        end),
    receive {mn_subbed, Tag} -> ok after 3000 -> erlang:error({mn_sub_timeout, Tag}) end,
    Forwarder.

wait_erlroute_mesh(_Nodes, Timeout) when Timeout =< 0 ->
    erlang:error(erlroute_mesh_not_formed);
wait_erlroute_mesh(Nodes, Timeout) ->
    Ready = lists:all(fun(N) ->
        case rpc:call(N, sys, get_state, [erlroute]) of
            #erlroute_state{erlroute_nodes = Ns} ->
                lists:all(fun(Other) -> lists:member(Other, Ns) end, Nodes -- [N]);
            _ ->
                false
        end
    end, Nodes),
    case Ready of
        true  -> ok;
        false -> timer:sleep(100), wait_erlroute_mesh(Nodes, Timeout - 100)
    end.

wait_remote_route_count(_Nodes, _Topic, _Expected, Timeout) when Timeout =< 0 ->
    erlang:error(remote_routes_not_ready);
wait_remote_route_count(Nodes, Topic, Expected, Timeout) ->
    MS = [{#subscriber{topic = Topic, dest_type = erlroute_on_other_node, _ = '_'}, [], [true]}],
    Ready = lists:all(fun(N) ->
        rpc:call(N, ets, select_count, ['$erlroute_subscribers', MS]) =:= Expected
    end, Nodes),
    case Ready of
        true  -> ok;
        false -> timer:sleep(100), wait_remote_route_count(Nodes, Topic, Expected, Timeout - 100)
    end.

collect_tagged_hits(Acc, Cap) ->
    case lists:sum(maps:values(Acc)) >= Cap of
        true ->
            Acc;
        false ->
            receive
                {mn_hit, Tag} ->
                    collect_tagged_hits(maps:update_with(Tag, fun(X) -> X + 1 end, 1, Acc), Cap)
            after 1000 ->
                Acc
            end
    end.

%% Symmetric node discovery: when a peer's erlroute starts after the dist
%% link is up (so the controller's nodeup check raced ahead of the peer
%% loading erlroute), both nodes must still end up knowing each other — no
%% manual nudging. Driven by cross_node_test_/0.
do_cross_node_symmetric_discovery() ->
    {ok, _} = application:ensure_all_started(erlroute),
    [_, Host] = string:split(atom_to_list(node()), "@"),
    {ok, Peer, PeerNode} = start_erlroute_peer(Host, "erlroute_disc"),
    Self = node(),
    try
        ok = wait_until(fun() ->
            lists:member(PeerNode, erlroute_nodes_of(Self))
                andalso lists:member(Self, erlroute_nodes_of(PeerNode))
        end, 8000)
    catch
        Class:Reason:ST ->
            catch peer:stop(Peer),
            application:stop(erlroute),
            erlang:raise(Class, Reason, ST)
    end,
    catch peer:stop(Peer),
    application:stop(erlroute),
    ok.

do_cross_node_discovery_settles() ->
    {ok, _} = application:ensure_all_started(erlroute),
    [_, Host] = string:split(atom_to_list(node()), "@"),
    {ok, PeerB, NodeB} = start_erlroute_peer(Host, "erlroute_settle_b"),
    {ok, PeerC, NodeC} = start_erlroute_peer(Host, "erlroute_settle_c"),
    Nodes = [node(), NodeB, NodeC],
    %% One counting tracer per node, local to that node, watching its own
    %% erlroute process' control-plane receives.
    Tracers = [start_control_tracer(N) || N <- Nodes],
    StopAll = fun() ->
        _ = [catch (T ! stop) || T <- Tracers],
        catch peer:stop(PeerB),
        catch peer:stop(PeerC),
        application:stop(erlroute)
    end,
    try
        ok = wait_erlroute_mesh(Nodes, 8000),
        %% Propagation churn: a live subscriber on every node for two shared
        %% topics, so descriptors are computed and broadcast to peers.
        _ = [subscribe_quiet(N, T)
             || N <- Nodes, T <- [<<"erlroute.settle.t1">>, <<"erlroute.settle.t2">>]],
        %% The aggregate control-message count must reach a fixed point and
        %% hold it for StableMs. Cap is far above the expected handshake +
        %% churn volume (~tens of messages) yet far below what a loop emits
        %% in a single poll interval.
        Stable = wait_count_stable(Tracers, 1500, 300, 15000),
        ?assert(Stable > 0),
        ?assert(Stable < 300)
    catch
        Class:Reason:ST ->
            StopAll(),
            erlang:raise(Class, Reason, ST)
    end,
    StopAll(),
    ok.

%% Spawn a counting tracer ON Node (so it is local to the traced erlroute)
%% and attach it to erlroute's 'receive' events.
start_control_tracer(Node) ->
    Tracer = spawn(Node, fun() -> control_tracer_loop(0) end),
    Pid = rpc:call(Node, erlang, whereis, [erlroute]),
    1 = rpc:call(Node, erlang, trace, [Pid, true, ['receive', {tracer, Tracer}]]),
    Tracer.

control_tracer_loop(Count) ->
    receive
        {trace, _P, 'receive', {erlroute_ping, _}}         -> control_tracer_loop(Count + 1);
        {trace, _P, 'receive', {erlroute_sync, _, _}}       -> control_tracer_loop(Count + 1);
        {trace, _P, 'receive', {set_remote_route, _, _, _}} -> control_tracer_loop(Count + 1);
        {trace, _P, 'receive', {remove_remote_route, _, _}} -> control_tracer_loop(Count + 1);
        {trace, _P, 'receive', _}                           -> control_tracer_loop(Count);
        {count, From}                                       -> From ! {control_count, self(), Count},
                                                               control_tracer_loop(Count);
        stop                                                -> ok
    end.

subscribe_quiet(Node, Topic) ->
    spawn(Node, fun() ->
        erlroute:sub(Topic, fun(_) -> ok end),
        receive _ -> ok after 30000 -> ok end
    end).

sum_control_counts(Tracers) ->
    lists:sum(lists:map(fun(T) ->
        T ! {count, self()},
        receive {control_count, T, K} -> K after 3000 -> erlang:error({control_count_timeout, T}) end
    end, Tracers)).

%% Poll the aggregate control-message count until it stays unchanged for
%% StableMs. Error if it ever exceeds Cap (endless loop) or fails to settle
%% within Budget.
wait_count_stable(Tracers, StableMs, Cap, Budget) ->
    wait_count_stable(Tracers, StableMs, Cap, Budget, -1, StableMs).

wait_count_stable(_Tracers, _StableMs, _Cap, Budget, Last, _Rem) when Budget =< 0 ->
    erlang:error({control_plane_never_settled, Last});
wait_count_stable(Tracers, StableMs, Cap, Budget, Last, Rem) ->
    timer:sleep(200),
    Now = sum_control_counts(Tracers),
    if
        Now > Cap ->
            erlang:error({control_plane_not_settling, Now});
        Now =:= Last andalso Rem =< 0 ->
            Now;
        Now =:= Last ->
            wait_count_stable(Tracers, StableMs, Cap, Budget - 200, Last, Rem - 200);
        true ->
            wait_count_stable(Tracers, StableMs, Cap, Budget - 200, Now, StableMs)
    end.

erlroute_nodes_of(Node) ->
    #erlroute_state{erlroute_nodes = Ns} = rpc:call(Node, sys, get_state, [erlroute]),
    Ns.

wait_until(_Pred, Timeout) when Timeout =< 0 ->
    erlang:error(condition_not_reached);
wait_until(Pred, Timeout) ->
    case Pred() of
        true  -> ok;
        false -> timer:sleep(100), wait_until(Pred, Timeout - 100)
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
