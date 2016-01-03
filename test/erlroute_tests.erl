-module(erlroute_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erlroute.hrl").

-define(TESTSERVER, erlroute).


% --------------------------------- fixtures ----------------------------------

% tests which doesn't require started erlroute as gen_server process
erlroute_non_started_test_() ->
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
    }.

% tests which require started erlroute as gen_server process
erlroute_started_test_() -> 
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

            {<<"When erlroute is going to start ets-table msg_routes must be created">>, 
                fun() ->
                    ?assertNotEqual(
                       undefined, 
                       ets:info(msg_routes)
                      ) 
                end},


            {<<"After subscribe, ets tables must present and route entry must present in ets">>, 
                fun() -> 
                    Type = by_module_name,
                    Source = test_producer,
                    Topic = <<"*">>,
                    Dest = self(),
                    DestType = pid,
                    EtsTable = erlroute:generate_routing_name(Type, Source),
                    erlroute:sub(sync, Type, Source, Topic, Dest, DestType),
                    MS = [{
                            #active_route{topic = Topic, dest = Dest, dest_type = DestType},
                            [],
                            [true]
                        }],
                    ?assertEqual(1, ets:select_count(EtsTable, MS))
                end}

        ]
    }.

setup_start() -> start_server().
cleanup() -> 
    case whereis(?TESTSERVER) of
          undefined -> ok;
          Pid -> stop_server(Pid)
    end.

start_server() -> ?TESTSERVER:start_link().
stop_server(_Pid) -> ?TESTSERVER:stop().
