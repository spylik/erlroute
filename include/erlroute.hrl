-define(PUB(Message), erlroute:pub(?MODULE, self(), ?LINE, mlibs:build_binary_key([?MODULE,?LINE]), Message).
-define(PUB(Topic,Message), erlroute:pub(?MODULE, self(), ?LINE, Topic, Message).

-record(msg_routes, {
        ets_name :: atom()
	}).

-export_type([
        flow_source/0,
        flow_dest/0,
        pubresult/0,
        topic/0
    ]).

-type pubtype() :: 'sync' | 'async' | 'hybrid'.
-type topic() :: binary().
-type proc() :: pid() | atom().
-type method() :: 'info' | 'cast' | 'call'.
-type id() :: {neg_integer(), pos_integer()}.
-type etsname() :: atom().
-type desttype() :: 'process' | 'poolboy'.
-type pubresult() :: [] | [proc()].

% only for cache for final topics (generated with module name)
-record(complete_routes, {
        topic :: topic(),
        dest_type :: desttype(),
        dest :: atom(),
        method = 'info' :: 'call' | 'cast' | 'info',
        parent_topic = 'undefined' :: 'undefined' | {etsname(), binary()}
	}).

-type complete_routes() :: #complete_routes{}.

% only for parametrize routes (generated with module name)
-record(parametrize_routes, {
        topic :: topic(),
        dest_type :: desttype(),
        dest :: atom(),
        method = 'info' ::'call' | 'cast' | 'info',
        words :: nonempty_list()
	}).

% for non-module specific subscribes
-record(subscribers_by_topic_only, {
        topic :: topic(),
        is_final_topic = true :: boolean(),
        words = 'undefined' :: 'undefined' | nonempty_list(),
        dest_type :: desttype(),
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
        topic = <<"*">> :: topic()
    }).

-type flow_source() :: #flow_source{} | [{'module', 'undefined' | module()} | {'topic', topic()}].
-type flow_dest() :: {process, proc(), method()} | {poolboy, atom(), method()}.


