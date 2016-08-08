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
-type id() :: {neg_integer(), pos_integer()}.

-record(active_route, {
        topic :: topic(),
        dest_type :: 'pid' | 'poolboy_pool',
        dest :: atom(),
        method = 'info' ::'call' | 'cast' | 'info',
        is_final_topic = true :: boolean(),
        parent_topic = 'undefined' :: 'undefined' | binary(),
        words = 'undefined' :: 'undefined' | nonempty_list()
	}).

-record(subscribers_by_topic_only, {
        topic :: topic(),
        topic_words :: nonempty_list(),
        module :: 'undefined' | module(),
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


