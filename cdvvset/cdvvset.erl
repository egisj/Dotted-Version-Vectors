
%%%-------------------------------------------------------------------
%%%
%%% File:      dvvset.erl
%%%
%%% @title Dotted Version Vector Set
%%% @author    Ricardo Tomé Gonçalves <tome.wave@gmail.com>
%%% @author    Paulo Sérgio Almeida <pssalmeida@gmail.com>
%%%
%%% @copyright The MIT License (MIT)
%%% Copyright (C) 2013
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
%%%
%%% @doc  
%%% An Erlang implementation of *compact* Dotted Version Vectors, which
%%% provides a container for a set of concurrent values (siblings) with causal
%%% order information.
%%%
%%% For further reading, visit the <a href="https://github.com/ricardobcl/Dotted-Version-Vectors/tree/compact">github page</a>.
%%% @end  
%%%
%%% @reference
%%% <a href="http://arxiv.org/abs/1011.5808">
%%% Dotted Version Vectors: Logical Clocks for Optimistic Replication
%%% </a>
%%% @end
%%%
%%%-------------------------------------------------------------------

-module(cdvvset).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([new/1,
         new/2,
         new_list/2,
         sync/1,
         join/1,
         update/2,
         update/3,
         size/1,
         ids/1,
         values/1,
         equal/2,
         less/2,
         map/2,
         last/2,
         lww/2,
         reconcile/2
        ]).

-export_type([clock/0, causal/0, id/0, value/0]).

% % @doc
%% STRUCTURE details:
%%      * entries() are sorted by id()
%%      * each counter() also includes the number of values in that id()
%%      * the values in each triple of entries() are causally ordered and each new value goes to the head of the list

-type clock()   :: {[entry()], anonym()}.
-type entries() :: [entry()].
-type entry()   :: {id(), counter(), dots(), values()}.
-type causal()  :: [{id(), counter(), dots()}].
-type dots()    :: [counter()].
-type values()  :: [{counter(), value()}].
-type anonym()  :: [value()].
-type id()      :: any().
-type value()   :: any().
-type counter() :: non_neg_integer().


%% @doc Constructs a new clock set without causal history,
%% and receives a list of values that gos to the anonymous list.
-spec new([value()]) -> clock().
new(Values) when is_list(Values) -> {[], Values};
new(V) -> {[], [V]}.

%% @doc Constructs a new clock set with the causal history
%% of the given version vector / vector clock,
%% and receives a list of values that gos to the anonymous list.
%% The version vector SHOULD BE a direct result of join/1.
-spec new_list(causal(), [value()]) -> clock().
new_list(Causal, Vs) when is_list(Vs) ->
    C2 = lists:sort(Causal),
    Clock = [{I,C,D,[]} || {I,C,D} <- C2],
    {Clock, Vs}.

-spec new(causal(), value()) -> clock().
new(Causal, V) ->
    C2 = lists:sort(Causal),
    Clock = [{I,C,D,[]} || {I,C,D} <- C2],
    {Clock, [V]}.

%% @doc Synchronizes a list of clocks using sync/2.
%% It discards (causally) outdated values, 
%% while merging all causal histories.
-spec sync([clock()]) -> clock().
sync(L) -> lists:foldl(fun sync/2, {}, L).

%% Private function
-spec sync(clock(), clock()) -> clock().
sync({}, C) -> C;
sync(C ,{}) -> C;
sync({E1,[]}, {E2,[]}) ->
    {sync(E1,E2,[]),[]};
sync(C1={E1,V1},C2={E2,V2}) ->
    V = case less(C1,C2) of
        true  -> V2; % C1 < C2 => return V2
        false -> case less(C2,C1) of
                    true  -> V1; % C2 < C1 => return V1
                    false -> % keep all unique anonymous values and sync entries()
                        sets:to_list(sets:from_list(V1++V2))
                 end
    end,
    {sync(E1,E2,[]),V}.

%% Private function
-spec sync(entries(), entries(), entries()) -> entries().
sync([], E2, Acc) -> lists:reverse(Acc, E2);
sync(E1, [], Acc) -> lists:reverse(Acc, E1);
sync([{I1,_,_,_}=H1 | T1]=C1, [{I2,_,_,_}=H2 | T2]=C2, Acc) ->
    if
      I1 < I2 -> sync(T1, C2, [H1 | Acc]);
      I1 > I2 -> sync(T2, C1, [H2 | Acc]);
      true    -> sync(T1, T2, [sync_dots(H1,H2) | Acc])
    end.

-spec sync_dots(entry(), entry()) -> entry().
sync_dots({I,C1,D1,V1}, {I,C2,D2,V2}) ->
    C = max(C1,C2),
    Dots = ordsets:union(D1, D2),
    {Dots2, Values} = discard(C,Dots,V1),
    {Dots3, Values2} = discard(C,Dots2,V2),
    {C2, Dots4} = lift(C,Dots3),
    {I, C2, Dots4, Values ++ Values2}.

discard(C, D, L) -> discard(C, D, L, []).
discard(_, D, [], Acc) -> {D, Acc};
discard(C, D, [{Dot,Val}|T], Acc) ->
    case Dot > C and (not ordsets:is_element(Dot, D)) of
        true  -> discard(C, D, T, [{Dot,Val} | Acc]);
        false -> discard(C, ordsets:add_element(Dot, D), T, Acc)
    end.

-spec lift(counter(), dots()) -> {counter(), dots()}.
lift(C, []) -> {C, []};
lift(C, [H|T])
    when H == C+1 -> lift(H, T);
lift(C, D) -> {C, D}.

%% @doc Return a dvvset w/o values that represents the causal history.
-spec join(clock()) -> causal().
join({Entries,_}) ->
    F = fun({I,C,D,V}) ->
            Dots = ordsets:from_list([Dot || {Dot,_} <- V]),
            D2 = ordsets:union(D,Dots),
            {C1,D1} = lift(C,D2),
            {I,C1,D1}
        end,
    [F(E) || E <- Entries].

%% @doc Advances the causal history with the given id.
%% The new value is the *anonymous dot* of the clock.
%% The client clock SHOULD BE a direct result of new/2.
-spec update(clock(), id()) -> clock().
update(C, I) ->
    {E,[V]} = C,
    {event(E, I, V), []}.

%% @doc Advances the causal history of the
%% first clock with the given id, while synchronizing
%% with the second clock, thus the new clock is
%% causally newer than both clocks in the argument.
%% The new value is the *anonymous dot* of the clock.
%% The first clock SHOULD BE a direct result of new/2,
%% which is intended to be the client clock with
%% the new value in the *anonymous dot* while
%% the second clock is from the local server.
-spec update(clock(), clock(), id()) -> clock().
update(C, S, I) ->
    {E,[V]} = C,
    %% Sync both clocks without the new value
    {C2,A} = sync({E,[]}, S),
    %% We create a new event on the synced causal history,
    %% with the id I and the new value.
    %% The anonymous values that were synced still remain.
    {event(C2, I, V), A}.

%% Private function
-spec event(entries(), id(), value()) -> entries().
event(C,I,V) -> 
    event(C,I,V,[]).

event([],I,V,Acc) -> 
    lists:reverse([{I,0,[],[{1,V}]} | Acc]);
event([H={I,C,D,V} | T], I, Val, Acc) ->
    lists:reverse([{I,C,D,[{max_id(I,H)+1,Val}|V]} | Acc],T);
event(C=[{I1,_,_,_} | _], I, V, Acc) 
    when I1 > I -> 
    lists:reverse(Acc, [{I,0,[],[{1,V}]} | C]);
event([H | T], I, V, Acc) -> 
    event(T, I, V, [H | Acc]).

-spec max_id(id(), entry()) -> counter().
max_id(I, {I,C,D,V}) ->
    D2 = [Dot || {Dot,_} <- V],
    lists:max([C | D] ++ D2).

%% @doc Returns the total number of values in this clock set.
-spec size(clock()) -> non_neg_integer().
size({C,Vs}) -> lists:sum([length(L) || {_,_,_,L} <- C]) + length(Vs).

%% @doc Returns all the ids used in this clock set.
-spec ids(clock()) -> [id()].
ids({C,_}) -> ([I || {I,_,_,_} <- C]).

%% @doc Returns all the values used in this clock set,
%% including the anonymous values.
-spec values(clock()) -> [value()].
values({C,Vs}) -> Vs ++ lists:append([L || {_,_,_,L} <- C]).

%% @doc Compares the equality of both clocks, regarding
%% only the causal histories, thus ignoring the values.
-spec equal(clock(), clock()) -> boolean().
equal({C1,_},{C2,_}) ->
    length(C1) =:= length(C2) andalso equal2(C1,C2).

equal2([], []) -> true;
equal2([{I, C1, D1, V1} | T1], [{I, C2, D2, V2} | T2]) 
    when length(V1) =:= length(V2) ->
%    {C11,D11} = lift(C1,D1),
%    {C22,D22} = lift(C2,D2),
    C1 =:= C2 andalso
    D1 =:= D2 andalso
    equal2(T1, T2);
equal2(_, _) -> false.

%% @doc Returns True if the first clock is causally older than
%% the second clock, thus values on the first clock are outdated.
%% Returns False otherwise.
-spec less(clock(), clock()) -> boolean().
less({C1,_}, {C2,_}) -> greater(C2, C1, false).

%% Private function
-spec greater(entries(), entries(), boolean()) -> boolean().
greater([], [], Strict) -> Strict;
greater([_|_], [], _) -> true;
greater([], [_|_], _) -> false;
greater([{I, C1, D1, _} | T1], [{I, C2, D2, _} | T2], Strict) ->
    F = fun(C,D) ->
            S = lists:seq(1,C),
            ordsets:union(S,D)
        end,
    case C1 =:= C2 andalso D1 =:= D2 of
        true ->
            greater(T1, T2, Strict);
        false ->
            case ordsets:is_subset(F(C2,D2), F(C1,D1)) of
                true ->
                    greater(T1, T2, true);
                false -> %C1 < C2
                    false
            end
    end;
greater([{I1, _, _, _} | T1], [{I2, _, _, _} | _]=C2, _) 
    when I1 < I2 -> greater(T1, C2, true);
greater(_, _, _) -> false.

%% @doc Maps (applies) a function on all values in this clock set,
%% returning the same clock set with the updated values.
-spec map(fun((value()) -> value()), clock()) -> clock().
map(F, {E,Vs}) ->
    F2 = fun({D,V}) -> {D,F(V)} end,
    {[ {I,C,D,lists:map(F2,V)} || {I,C,D,V} <- E], lists:map(F, Vs)}.

%% @doc Return a clock with the same causal history, but with only one
%% value in the anonymous placeholder. This value is the result of
%% the function F, which takes all values and returns a single new value.
-spec reconcile(Winner::fun(([value()]) -> value()), clock()) -> clock().
reconcile(F, C) ->
    V = F(values(C)),
    new(join(C),[V]).

%% @doc Returns the latest value in the clock set,
%% according to function F(A,B), which returns *true* if 
%% A compares less than or equal to B, false otherwise.
-spec last(LessOrEqual::fun((value(),value()) -> boolean()), clock()) -> value().
last(F, C) ->
   {_ ,_ , V2} = find_entry(F, C),
   V2.

%% @doc Return a clock with the same causal history, but with only one
%% value in its original position. This value is the newest value
%% in the given clock, according to function F(A,B), which returns *true*
%% if A compares less than or equal to B, false otherwise.
-spec lww(LessOrEqual::fun((value(),value()) -> boolean()), clock()) -> clock().
lww(F, C={E,_}) ->
    case find_entry(F, C) of
        {id, I, V}      -> {join_and_replace(I, V, E),[]};
        {anonym, _, V}  -> new(join(C),[V])
    end.

%% find_entry/2 - Private function
find_entry(F, {[], [V|T]}) -> 
    find_entry(F, null, V, {[],T}, anonym);
find_entry(F, {[{_,_,_,[]} | T], Vs}) -> 
    find_entry(F, {T,Vs});
find_entry(F, {[{I,_,_,[V|_]} | T], Vs}) -> 
    find_entry(F, I, V, {T,Vs}, id).

%% find_entry/5 - Private function
find_entry(F, I, V, C, Flag) ->
    Fun = fun (A,B) ->
        case F(A,B) of
            false -> {left,A}; % A is newer than B
            true  -> {right,B} % A is older than B
        end
    end,
    find_entry2(Fun, I, V, C, Flag).

%% find_entry2/5 - Private function
find_entry2(_, I, V, {[], []}, anonym) -> {anonym, I , V};
find_entry2(_, I, V, {[], []}, id) -> {id, I, V};
find_entry2(F, I, V, {[], [V1 | T]}, Flag) ->
    case F(V, V1) of
        {left,V2}  -> find_entry2(F, I, V2, {[],T}, Flag);
        {right,V2} -> find_entry2(F, I, V2, {[],T}, anonym)
    end;
find_entry2(F, I, V, {[{_,_,_,[]} | T], Vs}, Flag) -> find_entry2(F, I, V, {T, Vs}, Flag);
find_entry2(F, I, V, {[{I1,_,_,[V1|_]} | T], Vs}, Flag) -> 
    case F(V, V1) of
        {left,V2}  -> find_entry2(F, I, V2, {T, Vs}, Flag);
        {right,V2} -> find_entry2(F, I1, V2, {T, Vs}, Flag)
    end.

%% Private function
join_and_replace(Ir, V, E) -> 
    [if
       I == Ir -> {I, C, D, [V]};
       true    -> {I, C, D, []}
     end
     || {I, C, D, _} <- E].


%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).


join_test() ->
    A  = new([v1]),
    A1 = update(A,a),
    B  = new(join(A1),[v2]),
    B1 = update(B, A1, b),
    ?assertEqual( join(A)  , []             ),
    ?assertEqual( join(A1) , [{a,1}]        ),
    ?assertEqual( join(B1) , [{a,1},{b,1}]  ),
    ok.

update_test() ->
    A0 = update(new([v1]),a),
    A1 = update(new(join(A0),[v2]), A0, a),
    A2 = update(new(join(A1),[v3]), A1, b),
    A3 = update(new(join(A0),[v4]), A1, b),
    A4 = update(new(join(A0),[v5]), A1, a),
    ?assertEqual( A0 , {[{a,1,[v1]}],[]}                ),
    ?assertEqual( A1 , {[{a,2,[v2]}],[]}                ),
    ?assertEqual( A2 , {[{a,2,[]}, {b,1,[v3]}],[]}      ),
    ?assertEqual( A3 , {[{a,2,[v2]}, {b,1,[v4]}],[]}    ),
    ?assertEqual( A4 , {[{a,3,[v5,v2]}],[]}             ),
    ok.

sync_test() ->
    X   = {[{x,1,[]}],[]},
    A   = update(new([v1]),a),
    Y   = update(new([v2]),b),
    A1  = update(new(join(A),[v2]), a),
    A3  = update(new(join(A1),[v3]), b),
    A4  = update(new(join(A1),[v3]), c),
    F   = fun (L,R) -> L>R end,
    W   = {[{a,1,[]}],[]},
    Z   = {[{a,2,[v2,v1]}],[]},
    ?assertEqual( sync([W,Z])     , {[{a,2,[v2]}],[]}                         ),
    ?assertEqual( sync([W,Z])     , sync([Z,W])                               ),
    ?assertEqual( sync([A,A1])    , sync([A1,A])                              ),
    ?assertEqual( sync([A4,A3])   , sync([A3,A4])                             ),
    ?assertEqual( sync([A4,A3])   , {[{a,2,[]}, {b,1,[v3]}, {c,1,[v3]}],[]}   ),
    ?assertEqual( sync([X,A])     , {[{a,1,[v1]},{x,1,[]}],[]}                ),
    ?assertEqual( sync([X,A])     , sync([A,X])                               ),
    ?assertEqual( sync([X,A])     , sync([A,X])                               ),
    ?assertEqual( sync([A,Y])     , {[{a,1,[v1]},{b,1,[v2]}],[]}              ),
    ?assertEqual( sync([Y,A])     , sync([A,Y])                               ),
    ?assertEqual( sync([Y,A])     , sync([A,Y])                               ),
    ?assertEqual( sync([A,X])     , sync([X,A])                               ),
    ?assertEqual( lww(F,A4)     , sync([A4,lww(F,A4)])                        ),
    ok.

syn_update_test() ->
    A0  = update(new([v1]), a),             % Mary writes v1 w/o VV
    VV1 = join(A0),                         % Peter reads v1 with version vector (VV)
    A1  = update(new([v2]), A0, a),         % Mary writes v2 w/o VV
    A2  = update(new(VV1,[v3]), A1, a),     % Peter writes v3 with VV from v1
    ?assertEqual( VV1 , [{a,1}]                          ),
    ?assertEqual( A0  , {[{a,1,[v1]}],[]}                ),
    ?assertEqual( A1  , {[{a,2,[v2,v1]}],[]}             ),
    % now A2 should only have v2 and v3, since v3 was causally newer than v1
    ?assertEqual( A2  , {[{a,3,[v3,v2]}],[]}             ),
    ok.

event_test() ->
    {A,_} = update(new([v1]),a),
    ?assertEqual( event(A,a,v2) , [{a,2,[v2,v1]}]           ),
    ?assertEqual( event(A,b,v2) , [{a,1,[v1]}, {b,1,[v2]}]  ),
    ok.

lww_last_test() ->
    F  = fun (A,B) -> A =< B end,
    F2 = fun ({_,TS1}, {_,TS2}) -> TS1 =< TS2 end,
    X  = {[{a,4,[5,2]},{b,1,[]},{c,1,[3]}],[]},
    Y  = {[{a,4,[5,2]},{b,1,[]},{c,1,[3]}],[10,0]},
    Z  = {[{a,4,[5,2]}, {b,1,[1]}], [3]},
    A  = {[{a,4,[{5, 1002345}, {7, 1002340}]}, {b,1,[{4, 1001340}]}], [{2, 1001140}]},
    ?assertEqual( last(F,X) , 5                                         ),
    ?assertEqual( last(F,Y) , 10                                        ),
    ?assertEqual( lww(F,X)  , {[{a,4,[5]},{b,1,[]},{c,1,[]}],[]}        ),
    ?assertEqual( lww(F,Y)  , {[{a,4,[]},{b,1,[]},{c,1,[]}],[10]}       ),
    ?assertEqual( lww(F,Z)  , {[{a,4,[5]},{b,1,[]}],[]}                 ),
    ?assertEqual( lww(F2,A) , {[{a,4,[{5, 1002345}]}, {b,1,[]}], []}    ),
    ok.

reconcile_test() ->
    F1 = fun (L) -> lists:sum(L) end,
    F2 = fun (L) -> hd(lists:sort(L)) end,
    X  = {[{a,4,[5,2]},{b,1,[]},{c,1,[3]}],[]},
    Y  = {[{a,4,[5,2]},{b,1,[]},{c,1,[3]}],[10,0]},
    ?assertEqual( reconcile(F1,X) , {[{a,4,[]},{b,1,[]},{c,1,[]}],[10]} ),
    ?assertEqual( reconcile(F1,Y) , {[{a,4,[]},{b,1,[]},{c,1,[]}],[20]} ),
    ?assertEqual( reconcile(F2,X) , {[{a,4,[]},{b,1,[]},{c,1,[]}],[2]}  ),
    ?assertEqual( reconcile(F2,Y) , {[{a,4,[]},{b,1,[]},{c,1,[]}],[0]}  ),
    ok.

less_test() ->
    A  = update(new(v1),[a]),
    B  = update(new(join(A),[v2]), a),
    B2 = update(new(join(A),[v2]), b),
    B3 = update(new(join(A),[v2]), z),
    C  = update(new(join(B),[v3]), A, c),
    D  = update(new(join(C),[v4]), B2, d),
    ?assert(    less(A,B)  ),
    ?assert(    less(A,C)  ),
    ?assert(    less(B,C)  ),
    ?assert(    less(B,D)  ),
    ?assert(    less(B2,D) ),
    ?assert(    less(A,D)  ),
    ?assertNot( less(B2,C) ),
    ?assertNot( less(B,B2) ),
    ?assertNot( less(B2,B) ),
    ?assertNot( less(A,A)  ),
    ?assertNot( less(C,C)  ),
    ?assertNot( less(D,B2) ),
    ?assertNot( less(B3,D) ),
    ok.

equal_test() ->
    A = {[{a,4,[v5,v0]},{b,0,[]},{c,1,[v3]}], [v0]},
    B = {[{a,4,[v555,v0]}, {b,0,[]}, {c,1,[v3]}], []},
    C = {[{a,4,[v5,v0]},{b,0,[]}], [v6,v1]},
    % compare only the causal history
    ?assert(    equal(A,B) ),
    ?assert(    equal(B,A) ),
    ?assertNot( equal(A,C) ),
    ?assertNot( equal(B,C) ),
    ok.

size_test() ->
    ?assertEqual( 1 , ?MODULE:size(new([v1]))                                       ),
    ?assertEqual( 5 , ?MODULE:size({[{a,4,[v5,v0]},{b,0,[]},{c,1,[v3]}],[v4,v1]})   ),
    ok.

ids_values_test() ->
    A = {[{a,4,[v0,v5]},{b,0,[]},{c,1,[v3]}], [v1]},
    B = {[{a,4,[v0,v555]}, {b,0,[]}, {c,1,[v3]}], []},
    C = {[{a,4,[]},{b,0,[]}], [v1,v6]},
    ?assertEqual( ids(A)                , [a,b,c]       ),
    ?assertEqual( ids(B)                , [a,b,c]       ),
    ?assertEqual( ids(C)                , [a,b]         ),
    ?assertEqual( lists:sort(values(A)) , [v0,v1,v3,v5] ),
    ?assertEqual( lists:sort(values(B)) , [v0,v3,v555]  ),
    ?assertEqual( lists:sort(values(C)) , [v1,v6]       ),
    ok.

map_test() ->
    A = {[{a,4,[]},{b,0,[]},{c,1,[]}],[10]},
    B = {[{a,4,[5,0]},{b,0,[]},{c,1,[2]}],[20,10]},
    F = fun (X) -> X*2 end,
    ?assertEqual( map(F,A) , {[{a,4,[]},{b,0,[]},{c,1,[]}],[20]}            ),
    ?assertEqual( map(F,B) , {[{a,4,[10,0]},{b,0,[]},{c,1,[4]}],[40,20]}    ),
    ok.

-endif.
