-export_type([
        flow_dest/0,
        pub_result/0,
        topic/0
    ]).

-define(DEFAULT_ROUTER_POOL_SIZE, 10).
-define(REMOTETS, '$erlroute_remote_routes').

-record(erlroute_state, {
        erlroute_nodes = []     :: [node()],
        monitors = #{}          :: #{pid() => reference()}
    }).

-type erlroute_state()          :: #erlroute_state{}.

-type pub_type()                :: 'sync' | 'async'.
-type scope()                   :: 'all' | 'local'.
-type topic()                   :: binary().
-type proc()                    :: pid() | atom().
-type other_node_dest()         :: node() | {node(), proc()}.
-type payload()                 :: term().

-type proc_delivery_method()    :: 'info' | 'cast' | 'call'.
-type function_delivery_method():: {node(), 'cast' | 'call'}.
-type delivery_method()         :: proc_delivery_method() | function_delivery_method() | pub_type_based.

-type pub_result()              :: [{dest(), delivery_method()}].

-type static_function()         :: {module(), atom(), extra_arguments()}.
-type extra_arguments()         :: list().
-type shall_include_topic()     :: boolean().
-type fun_dest()                :: {fun() | static_function(), shall_include_topic()}.

-type dest_type()               :: 'process' | 'function' | 'erlroute_on_other_node' | 'process_on_other_node'.
-type dest()                    :: proc() | fun_dest() | other_node_dest().

-type sub_spec()                :: {dest_type(), dest(), delivery_method()}.

% ?REMOTETS: bag table keyed by #remote_sub.topic
-record(remote_sub, {
        topic                   :: topic()           | '_',
        node                    :: node()            | '_',
        dest_type               :: dest_type()       | '_',
        dest                    :: dest()            | '_',
        method                  :: delivery_method() | '_'
    }).

-type delivery_descriptor()     :: 'none'
                                |  {'direct', proc(), proc_delivery_method()}
                                |  {'pool', pid()}.

-type flow_dest()               :: {process, proc(), proc_delivery_method()}
                                |  {function, fun_dest(), function_delivery_method()}
                                |  {erlroute_on_other_node, {node(), pid()} | node(), pub_type_based}
                                |  {process_on_other_node, {node(), proc()}, proc_delivery_method()}.
