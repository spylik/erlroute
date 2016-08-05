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

parse_transform(AST, _Options) ->
%    io:format("~n~p~n", [Options]),
walk_ast([],AST,[],[],[]).

%-------------- walk_ast ----------------
% from module we need keep module name in AtrAcc

% parameterized module
walk_ast(Acc, [{attribute, _, module, {Module, _ModArg}}=H|T], _Module, _Name, _Arity) ->
    walk_ast([H|Acc], T, Module, [], []);
% standart module
walk_ast(Acc, [{attribute, _, module, Module}=H|T], _Module, _Name, _Arity) ->
    walk_ast([H|Acc], T, Module, [], []);
% dip only into functions
walk_ast(Acc, [{function, Line, Name, Arity, Clauses}|T], Module, _Name, _Arity) ->
    walk_ast([{function, Line, Name, Arity, walk_ast([], Clauses, Module, Name, Arity)}|Acc], T, Module, [], []);

%--------- walk function clauses --------
walk_ast(Acc, [{clause, Line, Arguments, Guards, Body}|T], Module, Name, Arity) ->
    walk_ast([{clause, Line, Arguments, Guards, walk_clause_body([], Body, Module, Name, Arity)}|Acc], T, Module, Name, Arity);

%------------- for the rest -------------
walk_ast(Acc, [H|T], Module, Name, Arity) ->
    walk_ast([H|Acc], T, Module, Name, Arity);

walk_ast(Acc, [], _Module, _Name, _Arity) -> 
    lists:reverse(Acc).

%----------- walk functions body --------
walk_clause_body(Acc, [H|T], Module, Name, Arity) ->
    walk_clause_body([try_transform(H, Module,Name, Arity)|Acc], T, Module, Name, Arity);

walk_clause_body(Acc, [], _Module, _Name, _Arity) ->
    lists:reverse(Acc).

%-------------- transform ---------------

% transform 
%   erlroute:pub(Message) 
% to 
%   erlroute:pub(Module, Pid, Line, Topic, Message)
% and generate Topic as <<"Module.Line">>

try_transform({call,Line,
        {remote,Line,
            {atom,Line,erlroute},{atom,Line,pub}
        },
        [
            Msg
        ]
    }, Module, _Name, _Arity) ->
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
                Msg 
            ]
        },
%        io:format("output is ~p",[Output]),
        Output;


% transform 
%   erlroute:pub(Topic,Message) 
% to 
%   erlroute:pub(Module, Pid, Line, Topic, Message)
try_transform({call,Line,
        {remote,Line,
            {atom,Line,erlroute},{atom,Line,pub}
        },
        [
            Topic,
            Msg
        ]
    }, Module, _Name, _Arity) ->
        Output = {call,Line,
            {remote,Line,
                {atom,Line,erlroute},{atom,Line,pub}
            },
            [
                {atom,Line,Module},
                {call, Line, {atom, Line ,self}, []},
                {integer, Line, Line},
                Topic,
                Msg 
            ]
        },
 %       io:format("output is ~p",[Output]),
        Output;

try_transform(BodyElement, _Module, _Name, _Arity) ->
    BodyElement.