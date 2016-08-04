% this record for keep internal message routing rules

-define(PUB(Topic,Message), erlroute:pub(?MODULE, self(), ?LINE, Topic, Message).

-record(msg_routes, {
        ets_name :: atom()
	}).
-record(active_route, {
        topic :: binary(),
        dest :: atom() | pid(),
        dest_type :: 'pid' | 'poolboy_pool'
	}).
