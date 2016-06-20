% this record for keep internal message routing rules
-record(msg_routes, {
        ets_name :: atom()
	}).
-record(active_route, {
        topic :: binary(),
        dest :: atom() | pid(),
        dest_type :: 'pid' | 'poolboy_pool'
	}). 
