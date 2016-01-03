-module(erlroute_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erlroute.hrl").

-define(TESTSERVER, erlroute).


% --------------------------------- fixtures ----------------------------------

% tests which doesn't require started erlroute as gen_server process
erlroute_non_started_test_() ->
    {inparallel,
        {setup,
            fun cleanup/0,
            [
                {<<"When erlroute doesn't start, ets-table msg_routes must be undefined">>, 
                    fun() -> 
                        ?assertEqual(
                            undefined, 
                            ets:info(msg_routes)
                        ) 
                    end},
        
                {<<"When erlroute doesn't start, process erlroute must be undegistered">>, 
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
                            erlroute:generate_routing_name(Type,Source), 
                            route_by_module_name_test_producer
                        )
                    end},
        
                {<<"generate_routing_name must generate correct ets table name when Type is by_pid">>, 
                    fun() ->
                        Type = by_pid,
                        Source = self(),
                        ?assertEqual(
                           erlroute:generate_routing_name(Type,Source), 
                           list_to_atom(
                           lists:concat([
                                atom_to_list(route_by_pid_), 
                                pid_to_list(Source)
                            ]))
                          )
                    end}
            ]
        }
    }.

% tests which require started erlroute as gen_server process
erlroute_started_test_() -> 
    {inparallel, 
        {setup,
             fun setup_start/0,
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
                         timer:sleep(50),
                         ?assertEqual(
                             true, 
                             is_pid(whereis(?TESTSERVER))
                         ) 
                     end},

                  {<<"Unknown gen_cast messages must do not crash gen_server">>,
                     fun() -> 
                         gen_server:cast(?TESTSERVER, {unknown, message}),
                         timer:sleep(50),
                         ?assertEqual(
                             true, 
                             is_pid(whereis(?TESTSERVER))
                         ) 
                     end},

                  {<<"Unknown gen_info messages must do not crash gen_server">>,
                     fun() -> 
                         ?TESTSERVER ! {unknown, message},
                         timer:sleep(50),
                         ?assertEqual(
                             true, 
                             is_pid(whereis(?TESTSERVER))
                         ) 
                     end},

                 {<<"When erlroute is going to start ets-table msg_routes must be created">>, 
                     fun() ->
                         ?assertNotEqual(
                            undefined, 
                            ets:info(msg_routes)
                           ) 
                     end},

                 % ------------------------ sync tests --------------------------- %
                 {<<"After sync sub/6, ets tables must present and route entry must present in ets">>, 
                     fun() -> 
                         Type = by_module_name,
                         Source = test_producer_sync6,
                         Topic = <<"*">>,
                         Dest = self(),
                         DestType = pid,
                         EtsTable = erlroute:generate_routing_name(Type, Source),
                         erlroute:sub(sync, Type, Source, Topic, Dest, DestType),
                         MS = [{
                                 #active_route{
                                     topic = Topic, 
                                     dest = Dest, 
                                     dest_type = DestType
                                 },
                                 [],
                                 [true]
                             }],
                         ?assertEqual(1, ets:select_count(EtsTable, MS))
                     end},
        
                 {<<"After multiple sync sub/6 attempts, ets tables must have only one route entry for each type/source">>, 
                     fun() -> 
                         Type = by_module_name,
                         Source = test_producer_sub_sync6_multiple,
                         Topic = <<"*">>,
                         Dest = self(),
                         DestType = pid,
                         EtsTable = erlroute:generate_routing_name(Type, Source),
                         erlroute:sub(sync, Type, Source, Topic, Dest, DestType),
                         erlroute:sub(sync, Type, Source, Topic, Dest, DestType),
                         erlroute:sub(sync, Type, Source, Topic, Dest, DestType),
                         MS = [{
                                 #active_route{
                                     topic = Topic, 
                                     dest = Dest, 
                                     dest_type = DestType
                                 },
                                [],
                                [true]
                             }],
                         ?assertEqual(1, ets:select_count(EtsTable, MS))
                     end},
        
                 {<<"Sync sub/5 must work same as sub/6 with DestType=pid">>, 
                     fun() -> 
                         Type = by_module_name,
                         Source = test_producer_sub_sync5,
                         Topic = <<"*">>,
                         Dest = self(),
                         DestType = pid,
                         EtsTable = erlroute:generate_routing_name(Type, Source),
                         erlroute:sub(sync, Type, Source, Topic, Dest),
                         MS = [{
                                 #active_route{
                                     topic = Topic, 
                                     dest = Dest, 
                                     dest_type = DestType
                                 },
                                 [],
                                 [true]
                             }],
                         ?assertEqual(1, ets:select_count(EtsTable, MS))
                     end},
        
                 {<<"After sync unsub/6, ets table must do not contain route entry">>,
                     fun() ->
                         Type = by_module_name,
                         Source = test_producer_unsub_sync6,
                         Topic = <<"*">>,
                         Dest = self(),
                         DestType = pid,
                         EtsTable = erlroute:generate_routing_name(Type, Source),
                         MS = [{
                                 #active_route{
                                     topic = Topic, 
                                     dest = Dest, 
                                     dest_type = DestType
                                 },
                                 [],
                                 [true]
                             }],
                         erlroute:sub(sync, Type, Source, Topic, Dest, DestType),
                         ?assertEqual(1, ets:select_count(EtsTable, MS)),
                         erlroute:unsub(sync, Type, Source, Topic, Dest, DestType),
                         ?assertEqual(0, ets:select_count(EtsTable, MS))
                     end},
        
                 {<<"Sync unsub/5 must work same as unsub/5 with DestType=pid">>,
                     fun() ->
                         Type = by_module_name,
                         Source = test_producer_unsub_sync5,
                         Topic = <<"*">>,
                         Dest = self(),
                         DestType = pid,
                         EtsTable = erlroute:generate_routing_name(Type, Source),
                         MS = [{
                                 #active_route{
                                     topic = Topic, 
                                     dest = Dest, 
                                     dest_type = DestType
                                 },
                                 [],
                                 [true]
                             }],
                         erlroute:sub(sync, Type, Source, Topic, Dest),
                         ?assertEqual(1, ets:select_count(EtsTable, MS)),
                         erlroute:unsub(sync, Type, Source, Topic, Dest),
                         ?assertEqual(0, ets:select_count(EtsTable, MS))
                     end},
        
                 % ---------------------- end of sync tests ---------------------- %
                 % ------------------------- async tests ------------------------- %
                 {<<"After async sub/6, ets tables must present and route entry must present in ets">>, 
                     fun() -> 
                         Type = by_module_name,
                         Source = test_producer_async6,
                         Topic = <<"*">>,
                         Dest = self(),
                         DestType = pid,
                         EtsTable = erlroute:generate_routing_name(Type, Source),
                         erlroute:sub(async, Type, Source, Topic, Dest, DestType),
                         MS = [{
                                 #active_route{
                                     topic = Topic, 
                                     dest = Dest, 
                                     dest_type = DestType
                                 },
                                 [],
                                 [true]
                             }],
                         timer:sleep(75),
                         ?assertEqual(1, ets:select_count(EtsTable, MS))
                     end},

                 {<<"After multiple async sub/6 attempts, ets tables must have only one route entry for each type/source">>, 
                     fun() -> 
                         Type = by_module_name,
                         Source = test_producer_sub_async6_multiple,
                         Topic = <<"*">>,
                         Dest = self(),
                         DestType = pid,
                         EtsTable = erlroute:generate_routing_name(Type, Source),
                         erlroute:sub(async, Type, Source, Topic, Dest, DestType),
                         erlroute:sub(async, Type, Source, Topic, Dest, DestType),
                         erlroute:sub(async, Type, Source, Topic, Dest, DestType),
                         MS = [{
                                 #active_route{
                                     topic = Topic, 
                                     dest = Dest, 
                                     dest_type = DestType
                                 },
                                [],
                                [true]
                             }],
                         timer:sleep(75),
                         ?assertEqual(1, ets:select_count(EtsTable, MS))
                     end},
        
                 {<<"Async sub/5 must work same as sub/6 with DestType=pid">>, 
                     fun() -> 
                         Type = by_module_name,
                         Source = test_producer_sub_async5,
                         Topic = <<"*">>,
                         Dest = self(),
                         DestType = pid,
                         EtsTable = erlroute:generate_routing_name(Type, Source),
                         erlroute:sub(async, Type, Source, Topic, Dest),
                         MS = [{
                                 #active_route{
                                     topic = Topic, 
                                     dest = Dest, 
                                     dest_type = DestType
                                 },
                                 [],
                                 [true]
                             }],
                         timer:sleep(75),
                         ?assertEqual(1, ets:select_count(EtsTable, MS))
                     end},

                 {<<"sub/4 must work same as sub/6 with sync DestType=pid">>, 
                     fun() -> 
                         Type = by_module_name,
                         Source = test_producer_sub_async5,
                         Topic = <<"*">>,
                         Dest = self(),
                         DestType = pid,
                         EtsTable = erlroute:generate_routing_name(Type, Source),
                         erlroute:sub(Type, Source, Topic, Dest),
                         MS = [{
                                 #active_route{
                                     topic = Topic, 
                                     dest = Dest, 
                                     dest_type = DestType
                                 },
                                 [],
                                 [true]
                             }],
                         timer:sleep(75),
                         ?assertEqual(1, ets:select_count(EtsTable, MS))
                     end},


                 {<<"After async unsub/6, ets table must do not contain route entry">>,
                     fun() ->
                         Type = by_module_name,
                         Source = test_producer_unsub_async6,
                         Topic = <<"*">>,
                         Dest = self(),
                         DestType = pid,
                         EtsTable = erlroute:generate_routing_name(Type, Source),
                         MS = [{
                                 #active_route{
                                     topic = Topic, 
                                     dest = Dest, 
                                     dest_type = DestType
                                 },
                                 [],
                                 [true]
                             }],
                         erlroute:sub(async, Type, Source, Topic, Dest, DestType),
                         timer:sleep(75),
                         ?assertEqual(1, ets:select_count(EtsTable, MS)),
                         erlroute:unsub(async, Type, Source, Topic, Dest, DestType),
                         timer:sleep(75),
                         ?assertEqual(0, ets:select_count(EtsTable, MS))
                     end},
        
                 {<<"Async unsub/5 must work same as unsub/6 with DestType=pid">>,
                     fun() ->
                         Type = by_module_name,
                         Source = test_producer_unsub_async5,
                         Topic = <<"*">>,
                         Dest = self(),
                         DestType = pid,
                         EtsTable = erlroute:generate_routing_name(Type, Source),
                         MS = [{
                                 #active_route{
                                     topic = Topic, 
                                     dest = Dest, 
                                     dest_type = DestType
                                 },
                                 [],
                                 [true]
                             }],
                         erlroute:sub(async, Type, Source, Topic, Dest),
                         timer:sleep(75),
                         ?assertEqual(1, ets:select_count(EtsTable, MS)),
                         erlroute:unsub(async, Type, Source, Topic, Dest),
                         timer:sleep(75),
                         ?assertEqual(0, ets:select_count(EtsTable, MS))
                     end},

                 {<<"Async unsub/4 must work same as unsub/6 with async DestType=pid">>,
                     fun() ->
                         Type = by_module_name,
                         Source = test_producer_unsub_async4,
                         Topic = <<"*">>,
                         Dest = self(),
                         DestType = pid,
                         EtsTable = erlroute:generate_routing_name(Type, Source),
                         MS = [{
                                 #active_route{
                                     topic = Topic, 
                                     dest = Dest, 
                                     dest_type = DestType
                                 },
                                 [],
                                 [true]
                             }],
                         erlroute:sub(Type, Source, Topic, Dest),
                         timer:sleep(75),
                         ?assertEqual(1, ets:select_count(EtsTable, MS)),
                         erlroute:unsub(Type, Source, Topic, Dest),
                         timer:sleep(75),
                         ?assertEqual(0, ets:select_count(EtsTable, MS))
                     end}
             ]
         }
     }.

setup_start() -> 
    error_logger:tty(false), 
    start_server().

cleanup() -> 
    case whereis(?TESTSERVER) of
          undefined -> ok;
          Pid -> stop_server(Pid)
    end.

start_server() -> ?TESTSERVER:start_link().
stop_server(_Pid) -> ?TESTSERVER:stop().
