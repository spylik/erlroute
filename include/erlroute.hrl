-define(PUB(Message), erlroute:pub(?MODULE, self(), ?LINE, mlibs:build_binary_key([?MODULE,?LINE]), Message).
-define(PUB(Topic,Message), erlroute:pub(?MODULE, self(), ?LINE, Topic, Message).

-record(msg_routes, {
        ets_name :: atom()
	}).

-export_type([
        flow_source/0,
        flow_dest/0
    ]).

-type topic() :: binary().
-type proc() :: pid() | atom().
-type method() :: 'info' | 'cast' | 'call'.

-record(active_route, {
        topic :: topic(),
        topic_childs = false :: boolean() | topic(),
        dest_type :: 'pid' | 'poolboy_pool',
        dest :: atom(),
        method = 'info' ::'call' | 'cast' | 'info'
	}).

-record(topics, {
        topic :: binary(),
        words :: list(),    % after binary:split(Topic, <<.>>).
        module :: atom(),
        line :: pos_integer(),
        process :: proc()
    }).

-record(flow_source, {
        module :: 'undefined' | module(),
        topic = <<"*">> :: binary()
    }).

-type flow_source() :: #flow_source{}.
-type flow_dest() :: {process, proc(), method()} | {poolboy, atom(), method()}.


