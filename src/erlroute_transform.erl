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
    -compile(nowarn_export_all).
-endif.

-export([parse_transform/2]).

-spec parse_transform(AST, Options) -> Result when
    AST     ::  [erl_parse:abstract_form() | erl_parse:form_info()],
    Options ::  list(),
    Result  ::  [erl_parse:abstract_form() | erl_parse:form_info()].

parse_transform(Forms, _Options) ->
    put(module, parse_trans:get_module(Forms)),
    parse_trans:plain_transform(fun do_transform/1, Forms).

% @doc transform erlroute:pub/1
-spec do_transform(erl_parse:abstract_form()) -> erl_parse:abstract_form() | continue.
do_transform(
    {call, _,
        {remote, _,
            {atom, Line,erlroute},{atom, _, pub}
        },
        [
            Msg
        ]
    }) ->
    RealLine = realline(Line),
    Module = get(module),
    EtsName = erlroute:cache_table(Module),
    Topic = lists:concat([Module,".",RealLine]),
    Output = {call,RealLine,
        {remote,RealLine,
            {atom,RealLine,erlroute},{atom,RealLine,pub}
        },
        [
            {atom,RealLine,Module},
            {call, RealLine, {atom, RealLine ,self}, []},
            {integer, RealLine, RealLine},
            {bin, RealLine, [{bin_element,RealLine,{string,RealLine,Topic},default,default}]},
            Msg,
            {atom, RealLine, hybrid},
            {atom, RealLine, EtsName}
        ]
    },
    Output;

% @doc transform erlroute:pub/2
do_transform(
    {call, _,
        {remote, _,
            {atom, Line, erlroute},{atom, _, pub}
        },
        [
            Topic,
            Msg
        ]
    }
) ->
    RealLine = realline(Line),
    Module = get(module),
    EtsName = erlroute:cache_table(Module),
    {call,Line,
        {remote,RealLine,
            {atom,RealLine,erlroute},{atom,RealLine,pub}
        },
        [
            {atom, RealLine,Module},
            {call, RealLine, {atom, RealLine ,self}, []},
            {integer, RealLine, RealLine},
            Topic,
            Msg,
            {atom, RealLine, hybrid},
            {atom, RealLine, EtsName}
        ]
    };
do_transform(_SomethingAnother) ->
    continue.

-spec realline(LineOrLineWithPosition) -> Result when
    LineOrLineWithPosition  :: {pos_integer(), pos_integer()} | pos_integer(),
    Result                  :: pos_integer().

realline({Line, _}) -> Line;
realline(Line) when is_integer(Line) -> Line.
