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

-type pubtype()                     :: 'sync' | 'async' | 'hybrid'.
-type topic()                       :: binary().
-type proc()                        :: pid() | atom().
-type fun_dest()                    :: {fun() | static_function(), shell_include_topic()}.
-type shell_include_topic()         :: boolean().

-type static_function() :: {module(), atom(), extra_arguments()}.
-type extra_arguments() :: list().

-type proc_delivery_method()        :: 'info' | 'cast' | 'call'.
-type function_delivery_method()    :: {node(), 'cast' | 'call'}.
-type delivery_method()             :: proc_delivery_method() | function_delivery_method().

-type etsname() :: atom().
-type desttype() :: 'process' | 'poolboy' | 'function'.
-type pubresult() :: [] | [proc()].
-type function_name() :: atom().

% only for cache for final topics (generated with module name)
-record(complete_routes, {
        dest_type :: desttype(),
        method = 'info' :: delivery_method(),
        dest :: proc() | fun_dest(),
        topic :: topic(),
        parent_topic = 'undefined' :: 'undefined' | {etsname(), binary()}
	}).

-type complete_routes() :: #complete_routes{}.

% only for parametrize routes (generated with module name)
-record(parametrize_routes, {
        dest_type :: desttype(),
        method = 'info' :: delivery_method(),
        dest :: proc() | fun_dest(),
        topic :: topic(),
        words :: nonempty_list()
	}).

% for non-module specific subscribes
-record(subscribers_by_topic_only, {
        topic :: topic(),
        is_final_topic = true :: boolean(),
        words = 'undefined' :: 'undefined' | nonempty_list(),
        dest_type :: desttype(),
        dest :: proc() | fun_dest(),
        method = 'info' :: delivery_method(),
        sub_ref :: integer()
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
-type flow_dest()   :: {process, proc(), proc_delivery_method()}
                     | {function, fun_dest(), function_delivery_method()}.


