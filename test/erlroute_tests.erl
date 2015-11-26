-module(erlroute_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TESTSERVER, erlroute).

% --------------------------------- fixtures ----------------------------------
erlroute_test_() ->
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
            {<<"When erlroute doesn't start, ets-table msg_routes should be undefined">>, 
                fun check_ets_not_present_when_stopped/0},

            {<<"When erlroute doesn't start, process erlroute should be undegistered">>, 
                fun unregistered_when_stopped/0},

            {<<"When erlroute is starting is going to register as erlroute">>, 
                fun start_and_check_registered/0},

            {<<"When erlroute is going to start ets-table msg_routes should be created">>, 
                fun start_and_check_ets/0}
        ]
    }.

% ============================= end of fixtures ===============================
% ---------------------------- tests function ---------------------------------

check_ets_not_present_when_stopped() ->
    ?assertEqual(undefined, ets:info(msg_routes)).

unregistered_when_stopped() ->
    ?assertEqual(false, is_pid(whereis(?TESTSERVER))).

start_and_check_registered() ->
    start_server(),
    ?assertEqual(true, is_pid(whereis(?TESTSERVER))).

start_and_check_ets() ->
    start_server(),
    ?assertNotEqual(undefined, ets:info(msg_routes)).

% ========================= end of tests functions ============================


start_server() -> ?TESTSERVER:start_link().
stop_server(_Pid) -> ?TESTSERVER:stop().
