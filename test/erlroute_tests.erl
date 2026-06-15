-module(erlroute_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erlroute.hrl").

-define(TESTSERVER, erlroute).

% tests for cover standard otp behaviour
otp_test_() ->
    {setup,
        fun disable_output/0,
        {inorder,
            [
                {<<"Application able to start via application:start()">>,
                    fun() ->
                        application:start(?TESTSERVER),
                        ?assertEqual(ok, application:ensure_started(?TESTSERVER)),
                        ?assertEqual(true, is_pid(whereis(?TESTSERVER)))
                    end},
                {<<"Application able to stop via application:stop()">>,
                    fun() ->
                        application:stop(?TESTSERVER),
                        ?assertEqual(false, is_pid(whereis(?TESTSERVER)))
                    end},
                {<<"Application able to start via ?TESTSERVER:start_link()">>,
                    fun() ->
                        ?TESTSERVER:start_link(),
                        ?assertEqual(true, is_pid(whereis(?TESTSERVER)))
                    end},
                {<<"Application able to stop via ?TESTSERVER:stop()">>,
                    fun() ->
                        ?assertEqual(ok, ?TESTSERVER:stop(sync)),
                        ?assertEqual(false, is_pid(whereis(?TESTSERVER)))
                    end},
                {<<"Application able to start and stop via start_link / stop(sync)">>,
                    fun() ->
                        ?TESTSERVER:start_link(),
                        ?assertEqual(ok, ?TESTSERVER:stop(sync)),
                        ?assertEqual(false, is_pid(whereis(?TESTSERVER)))
                    end},
                {<<"Application able to start and stop via start_link / stop()">>,
                    fun() ->
                        ?TESTSERVER:start_link(),
                        ?assertEqual(ok, ?TESTSERVER:stop()),
                        ?assertEqual(false, is_pid(whereis(?TESTSERVER)))
                    end},
                {<<"Application able to start and stop via start_link / stop(async)">>,
                    fun() ->
                        ?TESTSERVER:start_link(),
                        ?TESTSERVER:stop(async),
                        timer:sleep(1),
                        ?assertEqual(false, is_pid(whereis(?TESTSERVER)))
                    end}
            ]
        }
    }.

erlroute_non_started_test_() ->
    {setup,
        fun cleanup/0,
        {inparallel,
            [
                {<<"When erlroute not started, '$erlroute_subscribers' must be undefined">>,
                    fun() ->
                        ?assertEqual(undefined, ets:info('$erlroute_subscribers'))
                    end},
                {<<"When erlroute not started, process erlroute must be unregistered">>,
                    fun() ->
                        ?assertEqual(false, is_pid(whereis(?TESTSERVER)))
                    end}
            ]
        }
    }.

erlroute_started_test_() ->
    {setup,
        fun setup_start/0,
        fun cleanup/1,
        {inparallel,
            [
                {<<"When erlroute started it must be registered as erlroute">>,
                    fun() ->
                        ?assertEqual(true, is_pid(whereis(?TESTSERVER)))
                    end},
                {<<"Unknown gen_call messages must not crash gen_server">>,
                    fun() ->
                        _ = gen_server:call(?TESTSERVER, {unknown, message}),
                        timer:sleep(1),
                        ?assertEqual(true, is_pid(whereis(?TESTSERVER)))
                    end},
                {<<"Unknown gen_cast messages must not crash gen_server">>,
                    fun() ->
                        gen_server:cast(?TESTSERVER, {unknown, message}),
                        timer:sleep(1),
                        ?assertEqual(true, is_pid(whereis(?TESTSERVER)))
                    end},
                {<<"Unknown gen_info messages must not crash gen_server">>,
                    fun() ->
                        ?TESTSERVER ! {unknown, message},
                        timer:sleep(1),
                        ?assertEqual(true, is_pid(whereis(?TESTSERVER)))
                    end},
                {<<"When erlroute starts, '$erlroute_subscribers' must be present">>,
                    fun() ->
                        ?assertNotEqual(undefined, ets:info('$erlroute_subscribers'))
                    end}
            ]
        }
    }.

erlroute_pub_sub_test_() ->
    {setup,
        fun setup_start/0,
        fun cleanup/1,
        {inparallel,
            [
                {<<"sub/1 adds subscriber to '$erlroute_subscribers'">>,
                    fun() ->
                        Topic = <<"sub1.test.", (rand_bin())/binary>>,
                        erlroute:sub(Topic),
                        [{Topic, Subs}] = ets:lookup('$erlroute_subscribers', Topic),
                        ?assert(lists:member({process, self(), info}, Subs)),
                        erlroute:unsub(Topic)
                    end},
                {<<"sub/2 with explicit dest adds subscriber">>,
                    fun() ->
                        Topic = <<"sub2.dest.", (rand_bin())/binary>>,
                        erlroute:sub(Topic, {process, self(), cast}),
                        [{Topic, Subs}] = ets:lookup('$erlroute_subscribers', Topic),
                        ?assert(lists:member({process, self(), cast}, Subs)),
                        erlroute:unsub(Topic, {process, self(), cast})
                    end},
                {<<"duplicate sub is a no-op">>,
                    fun() ->
                        Topic = <<"dup.sub.", (rand_bin())/binary>>,
                        erlroute:sub(Topic),
                        erlroute:sub(Topic),
                        erlroute:sub(Topic),
                        [{Topic, Subs}] = ets:lookup('$erlroute_subscribers', Topic),
                        ?assertEqual(1, length(Subs)),
                        erlroute:unsub(Topic)
                    end},
                {<<"unsub removes subscriber">>,
                    fun() ->
                        Topic = <<"unsub.test.", (rand_bin())/binary>>,
                        erlroute:sub(Topic),
                        erlroute:unsub(Topic),
                        ?assertEqual([], ets:lookup('$erlroute_subscribers', Topic))
                    end},
                {<<"double unsub is safe">>,
                    fun() ->
                        Topic = <<"double.unsub.", (rand_bin())/binary>>,
                        erlroute:sub(Topic),
                        erlroute:unsub(Topic),
                        erlroute:unsub(Topic),
                        ?assertEqual([], ets:lookup('$erlroute_subscribers', Topic))
                    end},
                {<<"pub delivers message to single subscriber">>,
                    fun() ->
                        Topic = <<"deliver.single.", (rand_bin())/binary>>,
                        Dest  = spawn_collector(self()),
                        erlroute:sub(Topic, {process, Dest, info}),
                        Msg = make_ref(),
                        erlroute:pub(Topic, Msg),
                        ?assertEqual([Msg], drain()),
                        Dest ! stop
                    end},
                {<<"pub delivers to multiple subscribers">>,
                    fun() ->
                        Topic = <<"deliver.multi.", (rand_bin())/binary>>,
                        D1 = spawn_collector(self()),
                        D2 = spawn_collector(self()),
                        erlroute:sub(Topic, {process, D1, info}),
                        erlroute:sub(Topic, {process, D2, info}),
                        Msg = make_ref(),
                        erlroute:pub(Topic, Msg),
                        Received = drain(),
                        ?assertEqual([Msg, Msg], lists:sort(Received)),
                        D1 ! stop,
                        D2 ! stop
                    end},
                {<<"no delivery after unsub">>,
                    fun() ->
                        Topic = <<"no.deliver.after.unsub.", (rand_bin())/binary>>,
                        Dest = spawn_collector(self()),
                        erlroute:sub(Topic, {process, Dest, info}),
                        erlroute:unsub(Topic, {process, Dest, info}),
                        erlroute:pub(Topic, make_ref()),
                        timer:sleep(10),
                        ?assertEqual([], drain()),
                        Dest ! stop
                    end},
                {<<"any publisher module reaches topic subscriber">>,
                    fun() ->
                        Topic = <<"any.module.", (rand_bin())/binary>>,
                        Dest  = spawn_collector(self()),
                        erlroute:sub(Topic, {process, Dest, info}),
                        Msg1 = make_ref(),
                        Msg2 = make_ref(),
                        erlroute:pub(Topic, Msg1),
                        erlroute:pub(Topic, Msg2),
                        Received = drain(),
                        ?assertEqual(lists:sort([Msg1, Msg2]), lists:sort(Received)),
                        Dest ! stop
                    end},
                {<<"async pub delivers message">>,
                    fun() ->
                        Topic = <<"async.pub.", (rand_bin())/binary>>,
                        Dest  = spawn_collector(self()),
                        erlroute:sub(Topic, {process, Dest, info}),
                        Msg = make_ref(),
                        [] = erlroute:pub(Topic, Msg, async),
                        timer:sleep(20),
                        ?assertEqual([Msg], drain()),
                        Dest ! stop
                    end},
                {<<"function subscriber receives via cast">>,
                    fun() ->
                        Topic = <<"fun.sub.", (rand_bin())/binary>>,
                        Self  = self(),
                        erlroute:sub(Topic, fun(Payload) -> Self ! {fn, Payload} end),
                        Msg = make_ref(),
                        erlroute:pub(Topic, Msg),
                        timer:sleep(20),
                        receive {fn, Msg} -> ok
                        after 1000 -> error(timeout_waiting_for_fn_msg)
                        end
                    end},
                {<<"function subscriber with topic receives topic and payload">>,
                    fun() ->
                        Topic = <<"fun.topic.sub.", (rand_bin())/binary>>,
                        Self  = self(),
                        erlroute:sub(Topic, fun(T, P) -> Self ! {fn, T, P} end),
                        Msg = make_ref(),
                        erlroute:pub(Topic, Msg),
                        timer:sleep(20),
                        receive {fn, Topic, Msg} -> ok
                        after 1000 -> error(timeout_waiting_for_fn_topic_msg)
                        end
                    end}
            ]
        }
    }.

monitor_test_() ->
    {setup,
        fun setup_start/0,
        fun cleanup/1,
        {inorder, [
            {<<"duplicate subscribe for same pid creates exactly one monitor">>,
                fun() ->
                    Pid = spawn(fun() -> receive stop -> ok after 5000 -> ok end end),
                    Topic = <<"monitor.dup.", (rand_bin())/binary>>,
                    erlroute:sub(Topic, {process, Pid, info}),
                    erlroute:sub(Topic, {process, Pid, info}),
                    #erlroute_state{monitors = Monitors} = sys:get_state(erlroute),
                    ?assert(maps:is_key(Pid, Monitors)),
                    {monitored_by, Watchers} = process_info(Pid, monitored_by),
                    ?assertEqual(1, length([W || W <- Watchers, W =:= whereis(erlroute)])),
                    Pid ! stop
                end},
            {<<"unsub removes monitor when no subscriptions remain">>,
                fun() ->
                    Pid = spawn(fun() -> receive stop -> ok after 5000 -> ok end end),
                    Topic = <<"monitor.unsub.", (rand_bin())/binary>>,
                    erlroute:sub(Topic, {process, Pid, info}),
                    #erlroute_state{monitors = M1} = sys:get_state(erlroute),
                    ?assert(maps:is_key(Pid, M1)),
                    erlroute:unsub(Topic, {process, Pid, info}),
                    #erlroute_state{monitors = M2} = sys:get_state(erlroute),
                    ?assertNot(maps:is_key(Pid, M2)),
                    {monitored_by, Watchers} = process_info(Pid, monitored_by),
                    ?assertEqual([], [W || W <- Watchers, W =:= whereis(erlroute)]),
                    Pid ! stop
                end},
            {<<"unsub keeps monitor while other subscriptions for the pid remain">>,
                fun() ->
                    Pid = spawn(fun() -> receive stop -> ok after 5000 -> ok end end),
                    T1 = <<"monitor.keep.t1.", (rand_bin())/binary>>,
                    T2 = <<"monitor.keep.t2.", (rand_bin())/binary>>,
                    erlroute:sub(T1, {process, Pid, info}),
                    erlroute:sub(T2, {process, Pid, info}),
                    erlroute:unsub(T1, {process, Pid, info}),
                    #erlroute_state{monitors = M1} = sys:get_state(erlroute),
                    ?assert(maps:is_key(Pid, M1)),
                    erlroute:unsub(T2, {process, Pid, info}),
                    #erlroute_state{monitors = M2} = sys:get_state(erlroute),
                    ?assertNot(maps:is_key(Pid, M2)),
                    Pid ! stop
                end}
        ]}
    }.

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
                        ?assertEqual(Pid, erlroute:assign_router(Topic)),
                        ?assert(lists:member(Pid, Pool))
                    end},
                {<<"topics are spread round-robin across more than one router">>,
                    fun() ->
                        Assigned = [erlroute:assign_router(integer_to_binary(N))
                                    || N <- lists:seq(1, 200)],
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
    {ok, Peer, PeerNode} = start_erlroute_peer("erlroute_peer"),

    Cleanup = fun() ->
        catch peer:stop(Peer),
        application:stop(erlroute)
    end,

    try
        ok = wait_for_peer_in_erlroute_nodes(PeerNode, 3000),
        _ = sys:get_state(erlroute),

        run_remote_pub_variant(PeerNode, sync),
        run_remote_pub_variant(PeerNode, hybrid),
        run_remote_pub_variant(PeerNode, async),

        assert_assigned_router_dispatches_envelope(PeerNode),
        run_remote_pub_variant_process_cast(PeerNode),
        run_remote_pub_variant_function(PeerNode),
        run_multi_process_flips_to_pool(PeerNode),
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

    Forwarder = spawn(PeerNode,
        fun() ->
            erlroute:sub(Topic, {process, self(), info}),
            Self ! {subscribed, PubType},
            receive Msg -> Self ! {peer_received, PubType, Msg}
            after 10000 -> ok
            end
        end),

    receive
        {subscribed, PubType} -> ok
    after 3000 ->
        catch exit(Forwarder, kill),
        ?assertEqual({subscribed, PubType}, timeout)
    end,

    _ = sys:get_state(erlroute),

    erlroute:pub(Topic, Payload, PubType),

    receive
        {peer_received, PubType, Payload} -> ok
    after 5000 ->
        catch exit(Forwarder, kill),
        ?assertEqual({peer_received, PubType, Payload}, timeout)
    end.

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

    BypassMS = [{#remote_sub{topic = Topic, node = PeerNode,
                             dest_type = process_on_other_node,
                             dest = {PeerNode, RegName},
                             method = cast},
                 [], [true]}],
    ?assertEqual(1, ets:select_count(?REMOTETS, BypassMS)),
    RouterMS = [{#remote_sub{topic = Topic, node = PeerNode,
                             dest_type = erlroute_on_other_node, _ = '_'},
                 [], [true]}],
    ?assertEqual(0, ets:select_count(?REMOTETS, RouterMS)),

    erlroute:pub(Topic, Payload),

    receive
        {peer_cast_received, {'$gen_cast', Payload}} -> ok
    after 5000 ->
        catch exit(Forwarder, kill),
        ?assertEqual({peer_cast_received, {'$gen_cast', Payload}}, timeout)
    end.

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

    erlang:send(RouterPid, {remote_pub, Topic, Payload}),

    receive
        {peer_dispatched_async, Payload} -> ok
    after 5000 ->
        catch exit(Forwarder, kill),
        ?assertEqual({peer_dispatched_async, Payload}, timeout)
    end.

run_remote_pub_variant_function(PeerNode) ->
    Topic   = <<"erlroute.crossnode.remote_pub.function">>,
    Payload = {hello_function, erlang:unique_integer([positive])},
    Self    = self(),

    Forwarder = spawn(PeerNode,
        fun() ->
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

    ExpectedRouter = rpc:call(PeerNode, erlroute, assign_router, [Topic]),
    ?assert(is_pid(ExpectedRouter)),
    RouteMS = [{#remote_sub{topic = Topic, node = PeerNode,
                            dest_type = erlroute_on_other_node,
                            dest = {PeerNode, ExpectedRouter}, _ = '_'},
                [], [true]}],
    ?assertEqual(1, ets:select_count(?REMOTETS, RouteMS)),

    erlroute:pub(Topic, Payload),

    receive
        {peer_function_received, Payload} -> ok
    after 5000 ->
        catch exit(Forwarder, kill),
        ?assertEqual({peer_function_received, Payload}, timeout)
    end.

spawn_peer_process_subscriber(PeerNode, Topic, Method, Tag, ReportTo) ->
    spawn(PeerNode,
        fun() ->
            erlroute:sub(Topic, {process, self(), Method}),
            ReportTo ! {peer_subscribed, Tag},
            First = receive M -> M after 10000 -> none end,
            Extra = receive M2 -> {extra, M2} after 500 -> no_extra end,
            ReportTo ! {peer_got, Tag, First, Extra}
        end).

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

    PoolMS = [{#remote_sub{topic = Topic, node = PeerNode,
                           dest_type = erlroute_on_other_node, _ = '_'},
               [], [true]}],
    DirectMS = [{#remote_sub{topic = Topic, node = PeerNode,
                             dest_type = process_on_other_node, _ = '_'},
                 [], [true]}],
    ?assertEqual(1, ets:select_count(?REMOTETS, PoolMS)),
    ?assertEqual(0, ets:select_count(?REMOTETS, DirectMS)),

    erlroute:pub(Topic, Payload),

    assert_peer_got_once(p1, Payload),
    assert_peer_got_once(p2, Payload),
    catch exit(P1, kill),
    catch exit(P2, kill).

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

    PoolMS = [{#remote_sub{topic = Topic, node = PeerNode,
                           dest_type = erlroute_on_other_node, _ = '_'},
               [], [true]}],
    DirectMS = [{#remote_sub{topic = Topic, node = PeerNode,
                             dest_type = process_on_other_node, _ = '_'},
                 [], [true]}],
    ?assertEqual(1, ets:select_count(?REMOTETS, PoolMS)),
    ?assertEqual(0, ets:select_count(?REMOTETS, DirectMS)),

    erlroute:pub(Topic, Payload),

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

do_cross_node_multi_node_no_dup() ->
    _ = application:stop(erlroute),
    {ok, PeerA, NodeA} = start_erlroute_peer("erlroute_mn_a"),
    {ok, PeerB, NodeB} = start_erlroute_peer("erlroute_mn_b"),
    {ok, PeerC, NodeC} = start_erlroute_peer("erlroute_mn_c"),
    StopPeers = fun() -> [catch peer:stop(P) || P <- [PeerA, PeerB, PeerC]] end,
    Cleanup = fun() -> StopPeers(), application:stop(erlroute) end,
    Nodes = [NodeA, NodeB, NodeC],
    Topic = <<"erlroute.crossnode.multi_node">>,
    Self  = self(),

    try
        ok = wait_erlroute_mesh(Nodes, 8000),

        Forwarders = [subscribe_reporter(N, Topic, Tag, Self)
                      || {N, Tag} <- [{NodeA, a}, {NodeB, b}, {NodeC, c}]],

        ok = wait_remote_route_count(Nodes, Topic, 2, 8000),

        _ = rpc:call(NodeA, erlroute, pub,
                     [Topic, {mn_payload, erlang:unique_integer([positive])}]),

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
        true  -> {false, false};
        false ->
            StartedEpmd = case epmd_running() of
                true  -> false;
                false -> _ = os:cmd("epmd -daemon"), true
            end,
            Name = list_to_atom("erlroute_ct_" ++ os:getpid()),
            {ok, _} = net_kernel:start([Name, shortnames]),
            {StartedEpmd, true}
    end.

teardown_distribution({StartedEpmd, StartedNetKernel}) ->
    _ = case StartedNetKernel of
        true  -> net_kernel:stop();
        false -> ok
    end,
    _ = case StartedEpmd of
        true  -> os:cmd("epmd -kill");
        false -> ok
    end,
    ok.

epmd_running() ->
    case net_adm:names() of
        {ok, _}    -> true;
        {error, _} -> false
    end.

start_erlroute_peer(Prefix) ->
    Name = list_to_atom(Prefix ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Peer, Node} = peer:start_link(#{name => Name, host => "localhost",
                                         connection => standard_io,
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
    MS = [{#remote_sub{topic = Topic, dest_type = erlroute_on_other_node, _ = '_'}, [], [true]}],
    Ready = lists:all(fun(N) ->
        rpc:call(N, ets, select_count, [?REMOTETS, MS]) =:= Expected
    end, Nodes),
    case Ready of
        true  -> ok;
        false -> timer:sleep(100), wait_remote_route_count(Nodes, Topic, Expected, Timeout - 100)
    end.

collect_tagged_hits(Acc, Cap) ->
    case lists:sum(maps:values(Acc)) >= Cap of
        true -> Acc;
        false ->
            receive
                {mn_hit, Tag} ->
                    collect_tagged_hits(maps:update_with(Tag, fun(X) -> X+1 end, 1, Acc), Cap)
            after 1000 ->
                Acc
            end
    end.

do_cross_node_symmetric_discovery() ->
    {ok, _} = application:ensure_all_started(erlroute),
    {ok, Peer, PeerNode} = start_erlroute_peer("erlroute_disc"),
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
    {ok, PeerB, NodeB} = start_erlroute_peer("erlroute_settle_b"),
    {ok, PeerC, NodeC} = start_erlroute_peer("erlroute_settle_c"),
    Nodes = [node(), NodeB, NodeC],
    Tracers = [start_control_tracer(N) || N <- Nodes],
    StopAll = fun() ->
        _ = [catch (T ! stop) || T <- Tracers],
        catch peer:stop(PeerB),
        catch peer:stop(PeerC),
        application:stop(erlroute)
    end,
    try
        ok = wait_erlroute_mesh(Nodes, 8000),
        _ = [subscribe_quiet(N, T)
             || N <- Nodes, T <- [<<"erlroute.settle.t1">>, <<"erlroute.settle.t2">>]],
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
        {count, From} -> From ! {control_count, self(), Count}, control_tracer_loop(Count);
        stop          -> ok
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
        true  -> ok;
        false -> timer:sleep(50), wait_for_peer_in_erlroute_nodes(PeerNode, Timeout - 50)
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

rand_bin() -> integer_to_binary(erlang:unique_integer([positive])).

spawn_collector(Parent) ->
    spawn(fun() -> collector_loop(Parent) end).

collector_loop(Parent) ->
    receive
        stop -> ok;
        Msg  -> Parent ! {fwd, Msg}, collector_loop(Parent)
    end.

drain() ->
    receive
        {fwd, Data} -> [Data | drain()]
    after 50 -> []
    end.
