-define(PUB(Message), erlroute:pub(?MODULE, self(), ?LINE, mlibs:build_binary_key([?MODULE,?LINE]), Message).
-define(PUB(Topic,Message), erlroute:pub(?MODULE, self(), ?LINE, Topic, Message).

-export_type([
        flow_source/0,
        flow_dest/0,
        pub_result/0,
        topic/0
    ]).

-record(erlroute_state, {
        erlroute_nodes = []     :: [node()],
        monitors = #{}          :: #{pid() => reference()}
    }).

-type matchspec()           :: '_' | '$1' | '$2' | '$3' | '$4' | '$5'.

-type erlroute_state()          :: #erlroute_state{}.

-type pub_type()                :: 'sync' | 'async' | 'hybrid'.
-type topic()                   :: binary().
-type proc()                    :: pid() | atom().
-type other_node_dest()         :: node().
-type payload()                 :: term().


-type proc_delivery_method()    :: 'info' | 'cast' | 'call'.
-type function_delivery_method():: {node(), 'cast' | 'call'}.
-type delivery_method()         :: proc_delivery_method() | function_delivery_method() | pub_type_based.

-type ets_name()                :: atom().
-type pub_result()              :: [{dest(), delivery_method()}].
-type function_name()           :: atom().

-type static_function()         :: {module(), atom(), extra_arguments()}.
-type extra_arguments()         :: list().
-type shall_include_topic()     :: boolean().
-type fun_dest()                :: {fun() | static_function(), shall_include_topic()}.

-type dest_type()               :: 'process' | 'poolboy' | 'function' | 'erlroute_on_other_node'.
-type dest()                    :: proc() | fun_dest() | other_node_dest().

% only for cache for final topics (generated with module name)
-record(cached_route, {
        dest_type               :: dest_type() | matchspec(),
        method = 'info'         :: delivery_method() | matchspec(),
        dest                    :: dest() | matchspec(),
        topic                   :: topic() | matchspec(),
        parent_topic
            = 'undefined'       :: 'undefined' | {ets_name(), binary()} | matchspec()
    }).

-type cached_route() :: #cached_route{}.

% for non-module specific subscribes
-record(subscriber, {
        topic                   :: topic() | matchspec(),
        module                  :: module() | matchspec(),
        is_final_topic = true   :: boolean() | matchspec(),
        words = 'undefined'     :: 'undefined' | nonempty_list() | matchspec(),
        dest_type               :: dest_type() | matchspec(),
        dest                    :: dest() | matchspec(),
        method = 'info'         :: delivery_method() | matchspec(),
        sub_ref                 :: integer() | matchspec()
    }).

-record(topics, {
        topic                   :: binary(),
        words = []              :: list(),    % after binary:split(Topic, <<.>>).
        module                  :: atom(),
        line                    :: pos_integer(),
        process                 :: proc()
    }).

-record(flow_source, {
        module                  :: 'undefined' | module(),
        topic = <<"#">>         :: topic()
    }).

-type flow_source()             :: #flow_source{} | [{'module', 'undefined' | module()} | {'topic', topic()}].
-type flow_dest()               :: {process, proc(), proc_delivery_method()}
                                |  {poolboy, atom(), proc_delivery_method()}
                                |  {function, fun_dest(), function_delivery_method()}
                                |  {erlroute_on_other_node, node(), pub_type_based}.


