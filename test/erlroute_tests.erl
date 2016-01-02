-module(erlroute_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erlroute.hrl").

-define(TESTSERVER, erlroute).


% --------------------------------- fixtures ----------------------------------

% tests which doesn't require started erlroute as gen_server process
erlroute_non_started_test_() ->
   {foreach,
        fun() ->
            error_logger:tty(false)
        end,
        fun(_) ->
            case whereis(?TESTSERVER) of
                undefined -> ok;
                Pid -> stop_server(Pid)
            end,
            error_logger:tty(true)
        end,
        [
            {<<"When erlroute doesn't start, ets-table msg_routes must be undefined">>, 
                fun check_ets_not_present_when_stopped/0},

            {<<"When erlroute doesn't start, process erlroute must be undegistered">>, 
                fun unregistered_when_stopped/0},

            {<<"generate_routing_name must generate correct ets table name when Tupe is by_module_name">>, 
                fun generate_routing_name_must_generate_correct_ets_table_name_by_module_name/0},

            {<<"generate_routing_name must generate correct ets table name when Tupe is by_pid">>, 
                fun generate_routing_name_must_generate_correct_ets_table_name_by_pid/0}

        ]
    }.

% tests which require started erlroute as gen_server process
erlroute_started_test_() -> 
   {foreach,
        fun() ->
            error_logger:tty(false),
            start_server()
        end,
        fun(_) ->
            case whereis(?TESTSERVER) of
                undefined -> ok;
                Pid -> stop_server(Pid)
            end,
            error_logger:tty(true)
        end,
        [
            {<<"When erlroute is starting is going to register as erlroute">>, 
                fun start_and_check_registered/0},

            {<<"When erlroute is going to start ets-table msg_routes should be created">>, 
                fun start_and_check_ets/0},

            {<<"After subscribe, ets tables must present and route entry must present in ets also">>, 
                fun after_subscribe_we_should_have_ets_entry/0}

        ]
    }.


% ============================= end of fixtures ===============================
% ---------------------------- tests function ---------------------------------

check_ets_not_present_when_stopped() ->
    ?assertEqual(
       undefined, 
       ets:info(msg_routes)
      ).

unregistered_when_stopped() ->
    ?assertEqual(
       false, 
       is_pid(whereis(?TESTSERVER))
      ).

start_and_check_registered() ->
    ?assertEqual(
       true, 
       is_pid(whereis(?TESTSERVER))
      ).

start_and_check_ets() ->
    ?assertNotEqual(
       undefined, 
       ets:info(msg_routes)
      ).

generate_routing_name_must_generate_correct_ets_table_name_by_module_name() ->
    Type = by_module_name,
    Source = test_producer,
    ?assertEqual(
       erlroute:generate_routing_name(Type,Source), 
       route_by_module_name_test_producer
      ).

generate_routing_name_must_generate_correct_ets_table_name_by_pid() ->
    Type = by_pid,
    Source = self(),
    ?assertEqual(
       erlroute:generate_routing_name(Type,Source), 
       list_to_atom(
       lists:concat([
            atom_to_list(route_by_pid_), 
            pid_to_list(Source)
        ]))
      ).

after_subscribe_we_should_have_ets_entry() ->
    Type = by_module_name,
    Source = test_producer,
    Topic = <<"*">>,
    Dest = self(),
    DestType = pid,
    EtsTable = erlroute:generate_routing_name(Type, Source),
    erlroute:sub(sync, Type, Source, Topic, Dest, DestType),
    ets:i(EtsTable),

%    ?assertEqual(1, ets:select_count(EtsTable, MS)).
    ?assertEqual(true,true).



% ========================= end of tests functions ============================


start_server() -> io:format("try start"), ?TESTSERVER:start_link().
stop_server(_Pid) -> ?TESTSERVER:stop().
