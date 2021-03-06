%% --------------------------------------------------------------------------------
%% File:    erlroute_transform.erl
%% @author  Oleksii Semilietov <spylik@gmail.com>
%%
%% @doc
%% More documentation and examples at https://github.com/spylik/erlroute
%% @end
%% --------------------------------------------------------------------------------

-module(erlroute_transform).
-define(NOTEST, true).
-ifdef(TEST).
    -compile(export_all).
-endif.

-export([parse_transform/2]).

-spec parse_transform(AST, Options) -> Result when
    AST     ::  [erl_parse:abstract_form() | erl_parse:form_info()],
    Options ::  [compile:option()],
    Result  ::  [erl_parse:abstract_form() | erl_parse:form_info()].

parse_transform(Forms, _Options) ->
    put(module, parse_trans:get_module(Forms)),
    parse_trans:plain_transform(fun do_transform/1, Forms).

% @doc transform erlroute:pub/1
do_transform(
    {call,Line,
        {remote,Line,
            {atom,Line,erlroute},{atom,Line,pub}
        },
        [
            Msg
        ]
    }) ->
    Module = get(module),
    EtsName = erlroute:generate_complete_routing_name(Module),
    Topic = lists:concat([Module,".",Line]),
    Output = {call,Line,
        {remote,Line,
            {atom,Line,erlroute},{atom,Line,pub}
        },
        [
            {atom,Line,Module},
            {call, Line, {atom, Line ,self}, []},
            {integer, Line, Line},
            {bin, Line, [{bin_element,Line,{string,Line,Topic},default,default}]},
            Msg,
            {atom, Line, hybrid},
            {atom, Line, EtsName}
        ]
    },
    Output;

% @doc transform erlroute:pub/2
do_transform(
    {call,Line,
        {remote,Line,
            {atom,Line,erlroute},{atom,Line,pub}
        },
        [
            Topic,
            Msg
        ]
    }
) ->
    Module = get(module),
    EtsName = erlroute:generate_complete_routing_name(Module),
    Output = {call,Line,
        {remote,Line,
            {atom,Line,erlroute},{atom,Line,pub}
        },
        [
            {atom, Line,Module},
            {call, Line, {atom, Line ,self}, []},
            {integer, Line, Line},
            Topic,
            Msg,
            {atom, Line, hybrid},
            {atom, Line, EtsName}
        ]
    },
    Output;
do_transform(_) -> continue.
