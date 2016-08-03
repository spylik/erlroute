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
walk_ast([],AST,[]).

%-------------- walk_ast ----------------
% from module we need keep module name in AtrAcc

% parameterized module
walk_ast(Acc, [{attribute, _, module, {Module, _ModArg}}=H|T], _) ->
    walk_ast([H|Acc], T, Module);
% standart module
walk_ast(Acc, [{attribute, _, module, Module}=H|T], _) ->
    walk_ast([H|Acc], T, Module);

% we need dip only into functions
walk_ast(Acc, [{function, Line, Name, Arity, Clauses}|T], Module) ->
    walk_ast([{function, Line, Name, Arity, walk_clauses([], Clauses, Module, Name, Arity)}|Acc], T, Module);

walk_ast(Acc, [H|T], Module) ->
    walk_ast([H|Acc], T, Module);

walk_ast(Acc, [], _AtrAcc) ->
    lists:reverse(Acc).

%------------- walk_clauses -------------
walk_clauses(Acc, [{clause, Line, Arguments, Guards, Body}|T], Module, Name, Arity) ->
    walk_clauses([{clause, Line, Arguments, Guards, walk_clause_body([], Body, Module, Name, Arity)}|Acc], T, Module, Name, Arity);

walk_clauses(Acc, [], _Module, _Name, _Arity) -> 
    lists:reverse(Acc).

%----------- walk functions body --------
walk_clause_body(Acc, [H|T], Module, Name, Arity) ->
    walk_clause_body([try_transform(H, Module,Name, Arity)|Acc], T, Module, Name, Arity);

walk_clause_body(Acc, [], _Module, _Name, _Arity) ->
    lists:reverse(Acc).

%-------------- transform ---------------

% transform 
%   erlroute:pub(Topic,Message) 
% to 
%   erlroute:pub(Module, Pid, Line, Topic, Message)
try_transform({call,Line,
        {remote,Line,
            {atom,Line,erlroute},{atom,Line,pub}
        },
        [
            {bin,Line,[{bin_element,Line,{string,Line,Topic},default,default}]},
            {atom,Line,Msg}
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
                {bin,Line,[{bin_element,Line,{string,Line,Topic},default,default}]},
                {atom, Line, Msg}
            ]
        }, 
        %io:format("~n~p",[Output]), 
        Output;

try_transform(BodyElement, _Module, _Name, _Arity) ->
%    io:format("~n~p",[BodyElement]),
    BodyElement.
