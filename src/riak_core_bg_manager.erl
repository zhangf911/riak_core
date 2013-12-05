%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% @doc
%% We use two ETS tables to store critical data. In the event this process crashes,
%% the tables will be given back to the table manager and we can reclaim them when
%% we restart. Thus, limits and states are maintained across restarts of the
%% module, but not of the application. Since we are supervised by riak_core_sup,
%% that's fine.
%%
%% === Info Table ===
%% The table must be a set and is best if private. See ?BG_INFO_ETS_OPTS in MODULE.hrl.
%% Table Schema...
%% KEY                     Data                      Notes
%% ---                     ----                      -----
%% {info, Resource}        #resource_info            One token object per key.
%%
%% === Entries Table ===
%% The table must be a bag and is best if private. See ?BG_ENTRY_ETS_OPTS in MODULE.hrl.
%% KEY                     Data                      Notes
%% ---                     ----                      -----
%% {given, Resource}       #resource_entry           Multiple objects per key.
%% {blocked, Resource}  queue of #resource_entry(s)  One queue object per key.
%%
%% -------------------------------------------------------------------
-module(riak_core_bg_manager).

-behaviour(gen_server).

-include("riak_core_bg_manager.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([
         %% Universal
         start_link/0,
         enable/0,
         enable/1,
         disable/0,
         disable/1,
         disable/2,
         query_resource/3,
         all_resources/0,
         all_given/0,
         all_blocked/0,
         %% Locks
         concurrency_limit/1,
         set_concurrency_limit/2,
         set_concurrency_limit/3,
         concurrency_limit_reached/1,
         get_lock/1,
         get_lock/2,
         get_lock/3,
         get_lock_blocking/2,
         get_lock_blocking/3,
         get_lock_blocking/4,
         lock_info/0,
         lock_info/1,
         lock_count/1,
         all_locks/0,
         locks_held/0,
         locks_held/1, 
         locks_blocked/0,
         locks_blocked/1,
         %% Tokens
         set_token_rate/2,
         token_rate/1,
         get_token/1,
         get_token/2,
         get_token/3,
         get_token_blocking/2,
         get_token_blocking/3,
         get_token_blocking/4,
         token_info/0,
         token_info/1,
         all_tokens/0,
         tokens_given/0,
         tokens_given/1,
         tokens_blocked/0,
         tokens_blocked/1,
         %% Testing
         start/1
        ]).

%% reporting
-export([clear_history/0,
         head/0,
         head/1,
         head/2,
         head/3,
         tail/0,
         tail/1,
         tail/2,
         tail/3,
         ps/0,
         ps/1
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-define(NOT_TRANSFERED(S), S#state.info_table == undefined orelse S#state.entry_table == undefined).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the server
-spec start_link() -> {ok, pid()} | ignore | {error, term}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Test entry point to start stand-alone server
start(Interval) ->
    gen_server:start({local, ?SERVER}, ?MODULE, [Interval], []).

%% @doc Enable handing out of all locks and tokens
-spec enable() -> ok.
enable() ->
    gen_server:cast(?SERVER, enable).

%% @doc Disable handing out of all locks and tokens
-spec disable() -> ok.
disable() ->
    gen_server:cast(?SERVER, disable).

%% @doc Enable handing out resources of the kind specified. If the resource
%%      has not already been registered, this will have no effect.
-spec enable(bg_resource()) -> ok | unregistered.
enable(Resource) ->
    gen_server:cast(?SERVER, {enable, Resource}).

%% @doc Disable handing out resource of the given kind.
-spec disable(bg_resource()) -> ok | unregistered.
disable(Resource) ->
    gen_server:cast(?SERVER, {disable, Resource}).

%% @doc Disable handing out resource of the given kind. If kill == true,
%%      processes that currently hold the given resource will be killed.
-spec disable(bg_resource(), boolean()) -> ok | unregistered.
disable(Resource, Kill) ->
    gen_server:cast(?SERVER, {disable, Resource, Kill}).

%% @doc Query the current set of registered resources by name, states, and types.
%%      The special atom 'all' querys all resources. A list of states and a list
%%      of types allows selective query.
-spec query_resource(bg_resource() | all, [bg_state()], [bg_resource_type()]) -> [bg_stat_live()].
query_resource(Resource, States, Types) ->
    gen_server:call(?SERVER, {query_resource, Resource, States, Types}, infinity).

%% @doc Get a list of all resources of all types in all states
-spec all_resources() -> [bg_stat_live()].
all_resources() ->
    query_resource(all, [given, blocked], [token, lock]).

%% @doc Get a list of all resources of all kinds in the given state
-spec all_given() -> [bg_stat_live()].
all_given() ->
    query_resource(all, [given], [token, lock]).

%% @doc Get a list of all resources of all kinds in the blocked state
-spec all_blocked() -> [bg_stat_live()].
all_blocked() ->
    query_resource(all, [blocked], [token, lock]).

%%%%%%%%%%%
%% Lock API
%%%%%%%%%%%

%% @doc Get the current maximum concurrency for the given lock type.
-spec concurrency_limit(bg_lock()) -> bg_concurrency_limit().
concurrency_limit(Lock) ->
    gen_server:call(?MODULE, {concurrency_limit, Lock}, infinity).

%% @doc same as `set_concurrency_limit(Type, Limit, false)'
-spec set_concurrency_limit(bg_lock(), bg_concurrency_limit()) -> bg_concurrency_limit().
set_concurrency_limit(Lock, Limit) ->
    set_concurrency_limit(Lock, Limit, false).

%% @doc Set a new maximum concurrency for the given lock type and return
%%      the previous maximum or default. If more locks are held than the new
%%      limit how they are handled depends on the value of `Kill'. If `true',
%%      then the extra locks are released by killing processes with reason `max_concurrency'.
%%      If `false', then the processes holding the extra locks are aloud to do so until they
%%      are released.
-spec set_concurrency_limit(bg_lock(), bg_concurrency_limit(), boolean()) -> bg_concurrency_limit().
set_concurrency_limit(Lock, Limit, Kill) ->
    gen_server:call(?MODULE, {set_concurrency_limit, Lock, Limit, Kill}, infinity).

%% @doc Returns true if the number of held locks is at the limit for the given lock type
-spec concurrency_limit_reached(bg_lock()) -> boolean().
concurrency_limit_reached(Lock) ->
    gen_server:call(?MODULE, {lock_limit_reached, Lock}, infinity).

%% @doc Acquire a concurrency lock of the given name, if available,
%%      and associate the lock with the calling process. Returns the
%%      reference to the monitored process or max_concurrency.
-spec get_lock(bg_lock()) -> {ok, reference()} | max_concurrency.
get_lock(Lock) ->
    get_lock(Lock, self()).

%% @doc Acquire a concurrency lock, if available, and associate the
%%      lock with the provided pid or metadata. If metadata
%%      is provided the lock is associated with the calling process
%%      If no locks are available, max_concurrency is returned.
-spec get_lock(bg_lock(), pid() | [{atom(), any()}]) -> {ok, reference()} | max_concurrency.
get_lock(Lock, Pid) when is_pid(Pid) ->
    get_lock(Lock, Pid, []);
get_lock(Lock, Opts) when is_list(Opts)->
    get_lock(Lock, self(), Opts).

%% @doc Acquire a concurrency lock, if available,  and associate
%%      the lock with the provided pid and metadata.
-spec get_lock(bg_lock(), pid(), [{atom(), any()}]) -> {ok, reference()} | max_concurrency.
get_lock(Lock, Pid, Meta) ->
    gen_server:call(?MODULE, {get_lock, Lock, Pid, Meta}, infinity).

%% @doc Get a lock and block if those locks are currently at max_concurrency, until
%%      a lock is released. Associate lock with provided pid or metadata.
%%      If metadata is provided, the lock is associated with the calling process.
%%      If the lock is not given before Timeout milliseconds, the call will
%%      return with 'timeout'.
-spec get_lock_blocking(bg_lock(), pid() | [{atom(), any()}], timeout()) -> {ok, reference()} | unregistered | timeout.
get_lock_blocking(Lock, Pid, Timeout) when is_pid(Pid) ->
    get_lock_blocking(Lock, Pid, [], Timeout);
get_lock_blocking(Lock, Meta, Timeout) ->
    get_lock_blocking(Lock, self(), Meta, Timeout).

-spec get_lock_blocking(bg_lock(), timeout()) -> {ok, reference()} | unregistered.
get_lock_blocking(Lock, Timeout) ->
    get_lock_blocking(Lock, self(), Timeout).

-spec get_lock_blocking(bg_lock(), pid(), [{atom(), any()}], timeout()) -> {ok, reference} | unregistered | timeout.
get_lock_blocking(Lock, Pid, Meta, Timeout) ->
    gen_server:call(?SERVER, {get_lock_blocking, Lock, Pid, Meta, Timeout}, infinity).

%% @doc Return the current concurrency count of the given lock type.
-spec lock_count(bg_lock()) -> integer() | unregistered.
lock_count(Lock) ->
    gen_server:call(?MODULE, {lock_count, Lock}, infinity).

%% @doc Return list of lock types and associated info. To be returned in this list
%%      a lock type must have had its concurrency set or have been enabled/disabled.
-spec lock_info() -> [{bg_lock(), boolean(), bg_concurrency_limit()}].
lock_info() ->
    gen_server:call(?MODULE, lock_info, infinity).

%% @doc Return the registration info for the named Lock
-spec lock_info(bg_lock()) -> {boolean(), bg_concurrency_limit()} | unregistered.
lock_info(Lock) ->
    gen_server:call(?MODULE, {lock_info, Lock}, infinity).

%% @doc Returns all locks, held or blocked.
-spec all_locks() -> [bg_stat_live()].
all_locks() ->
    query_resource(all, [given, blocked], [lock]).


%% @doc Returns all currently held locks or those that match Lock
-spec locks_held() -> [bg_stat_live()].
locks_held() ->
    locks_held(all).

-spec locks_held(bg_lock() | all) -> [bg_stat_live()].
locks_held(Lock) ->
    query_resource(Lock, [given], [lock]).

%% @doc Returns all currently blocked locks.
locks_blocked() ->
    locks_blocked(all).

-spec locks_blocked(bg_lock() | all) -> [bg_stat_live()].
locks_blocked(Lock) ->
    query_resource(Lock, [blocked], [token]).

%%%%%%%%%%%%
%% Token API
%%%%%%%%%%%%

%% @doc Set the refill rate of tokens. Return previous value.
-spec set_token_rate(bg_token(), bg_rate()) -> bg_rate().
set_token_rate(_Token, undefined) -> undefined;
set_token_rate(Token, Rate={_Period, _Count}) ->
    gen_server:call(?SERVER, {set_token_rate, Token, Rate}, infinity).

%% @doc Get the current refill rate of named token.
-spec token_rate(bg_token()) -> bg_rate().
token_rate(Token) ->
    gen_server:call(?SERVER, {token_rate, Token}, infinity).

%% @doc Get a token without blocking.
%%      Associate token with provided pid or metadata. If metadata
%%      is provided the lock is associated with the calling process.
%%      Returns "max_concurrency" if empty.
-spec get_token(bg_token(), pid() | [{atom(), any()}]) -> ok | max_concurrency.
get_token(Token, Pid) when is_pid(Pid) ->
    get_token(Token, Pid, []);
get_token(Token, Meta) ->
    get_token(Token, self(), Meta).

-spec get_token(bg_token()) -> ok | max_concurrency.
get_token(Token) ->
    get_token(Token, self()).

-spec get_token(bg_token(), pid(), [{atom(), any()}]) -> ok | max_concurrency.
get_token(Token, Pid, Meta) ->
    gen_server:call(?SERVER, {get_token, Token, Pid, Meta}, infinity).

%% @doc Get a token and block if those tokens are currently empty, until the
%%      tokens are refilled. Associate token with provided pid or metadata.
%%      If metadata is provided, the token is associated with the calling process.
-spec get_token_blocking(bg_token(), pid() | [{atom(), any()}], timeout()) -> ok | timeout.
get_token_blocking(Token, Pid, Timeout) when is_pid(Pid) ->
    get_token_blocking(Token, Pid, [], Timeout);
get_token_blocking(Token, Meta, Timeout) ->
    get_token_blocking(Token, self(), Meta, Timeout).

-spec get_token_blocking(bg_token(), timeout()) -> ok.
get_token_blocking(Token, Timeout) ->
    get_token_blocking(Token, self(), Timeout).

-spec get_token_blocking(bg_token(), pid(), [{atom(), any()}], timeout()) -> ok | timeout.
get_token_blocking(Token, Pid, Meta, Timeout) ->
    gen_server:call(?SERVER, {get_token_blocking, Token, Pid, Meta, Timeout}, infinity).

%% @doc Return list of token kinds and associated info. To be returned in this list
%%      a token must have had its rate set.
-spec token_info() -> [{bg_token(), boolean(), bg_rate()}].
token_info() ->
    gen_server:call(?MODULE, token_info, infinity).

%% @doc Return the registration info for the named Token
-spec token_info(bg_token()) -> {boolean(), bg_rate()}.
token_info(Token) ->
    gen_server:call(?MODULE, {token_info, Token}, infinity).

-spec all_tokens() -> [bg_stat_live()].
all_tokens() ->
    query_resource(all, [given, blocked], [token]).

%% @doc Get a list of token resources in the given state.
tokens_given() ->
    tokens_given(all).
-spec tokens_given(bg_token() | all) -> [bg_stat_live()].
tokens_given(Token) ->
    query_resource(Token, [given], [token]).

%% @doc Get a list of token resources in the blocked state.
tokens_blocked() ->
    tokens_blocked(all).
tokens_blocked(Token) ->
    query_resource(Token, [blocked], [token]).

%% Stats/Reporting

clear_history() ->
    gen_server:cast(?SERVER, clear_history).

%% List history of token manager
%% @doc show history of token request/grants over default and custom intervals.
%%      offset is forwards-relative to the oldest sample interval
-spec head() -> [[bg_stat_hist()]].
head() ->
        head(all).
-spec head(bg_token()) -> [[bg_stat_hist()]].
head(Token) ->
        head(Token, ?BG_DEFAULT_OUTPUT_SAMPLES).
-spec head(bg_token(), non_neg_integer()) -> [[bg_stat_hist()]].
head(Token, NumSamples) ->
    head(Token, 0, NumSamples).
-spec head(bg_token(), non_neg_integer(), bg_count()) -> [[bg_stat_hist()]].
head(Token, Offset, NumSamples) ->
    gen_server:call(?SERVER, {head, Token, Offset, NumSamples}, infinity).

%% @doc return history of token request/grants over default and custom intervals.
%%      offset is backwards-relative to the newest sample interval
-spec tail() -> [[bg_stat_hist()]].
tail() ->
    tail(all).
-spec tail(bg_token()) -> [[bg_stat_hist()]].
tail(Token) ->
    tail(Token, ?BG_DEFAULT_OUTPUT_SAMPLES).
-spec tail(bg_token(), bg_count()) -> [[bg_stat_hist()]].
tail(Token, NumSamples) ->
    tail(Token, NumSamples, NumSamples).
-spec tail(bg_token(), bg_count(), bg_count()) -> [[bg_stat_hist()]].
tail(Token, Offset, NumSamples) ->
    gen_server:call(?SERVER, {tail, Token, Offset, NumSamples}, infinity).

%% @doc List most recent requests/grants for all tokens and locks
-spec ps() -> [bg_stat_live()].
ps() ->
    ps(all).
%% @doc List most recent requests/grants for named resource or one of
%%      either 'token' or 'lock'. The later two options will list all
%%      resources of that type in the given/locked or blocked state.
-spec ps(bg_resource() | token | lock) -> [bg_stat_live()].
ps(Arg) ->
    gen_server:call(?SERVER, {ps, Arg}, infinity).

%%%===================================================================
%%% Data Structures
%%%===================================================================

-type bg_limit() :: bg_concurrency_limit() | bg_rate().

%% General settings of a lock type.
-record(resource_info,
        {type      :: bg_resource_type(),
         limit     :: bg_limit(),
         enabled   :: boolean()}).

-define(resource_type(X), (X)#resource_info.type).
-define(resource_limit(X), (X)#resource_info.limit).
-define(resource_enabled(X), (X)#resource_info.enabled).

-define(DEFAULT_CONCURRENCY, 0). %% DO NOT CHANGE. DEFAULT SET TO 0 TO ENFORCE "REGISTRATION"
-define(DEFAULT_RATE, undefined).%% DO NOT CHANGE. DEFAULT SET TO 0 TO ENFORCE "REGISTRATION"
-define(DEFAULT_LOCK_INFO, #resource_info{type=lock, enabled=true, limit=?DEFAULT_CONCURRENCY}).
-define(DEFAULT_TOKEN_INFO, #resource_info{type= token, enabled=true, limit=?DEFAULT_RATE}).

%% An instance of a resource entry in "given" or "blocked"
-record(resource_entry,
        {resource  :: bg_resource(),
         type      :: bg_resource_type(),
         pid       :: pid(),           %% owning process
         meta      :: bg_meta(),       %% associated metadata
         from      :: {pid(), term()}, %% optional reply-to for blocked resources
         ref       :: reference(),     %% optional monitor reference to owning process
         state     :: bg_state()        %% state of item on given or blocked queue
        }).

-define(RESOURCE_ENTRY(Resource, Type, Pid, Meta, From, Ref, State),
        #resource_entry{resource=Resource, type=Type, pid=Pid, meta=Meta, from=From, ref=Ref, state=State}).
-define(e_resource(X), (X)#resource_entry.resource).
-define(e_type(X), (X)#resource_entry.type).
-define(e_pid(X), (X)#resource_entry.pid).
-define(e_meta(X), (X)#resource_entry.meta).
-define(e_from(X), (X)#resource_entry.from).
-define(e_ref(X), (X)#resource_entry.ref).
-define(e_state(X), (X)#resource_entry.state).

%%%
%%% Gen Server State record
%%%

-record(state,
        {info_table:: ets:tid(),          %% TableID of ?BG_INFO_ETS_TABLE
         entry_table:: ets:tid(),         %% TableID of ?BG_ENTRY_ETS_TABLE
         %% NOTE: None of the following data is persisted across process crashes.
         enabled :: boolean(),            %% Global enable/disable switch, true at startup
         %% stats
         window  :: orddict:orddict(),    %% bg_resource() -> bg_stat_hist()
         history :: queue(),              %% bg_resource() -> queue of bg_stat_hist()
         window_interval :: bg_period(),  %% history window size in milliseconds
         window_tref :: reference()       %% reference to history window sampler timer
        }).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec init([]) -> {ok, #state{}} |
                  {ok, #state{}, non_neg_integer() | infinity} |
                  ignore |
                  {stop, term()}.
init([]) ->
    init([?BG_DEFAULT_WINDOW_INTERVAL]);
init([Interval]) ->
    lager:debug("Background Manager starting up."),
    %% Claiming a table will result in a handle_info('ETS-TRANSFER', ...) message.
    %% We have two to claim...
    ok = riak_core_table_manager:claim_table(?BG_INFO_ETS_TABLE),
    ok = riak_core_table_manager:claim_table(?BG_ENTRY_ETS_TABLE),
    State = #state{info_table=undefined, %% resolved in the ETS-TRANSFER handler
                   entry_table=undefined, %% resolved in the ETS-TRANSFER handler
                   window=orddict:new(),
                   enabled=true,
                   window_interval=Interval,
                   history=queue:new()},
    State2 = schedule_sample_history(State),
    {ok, State2}.

%% @private
%% @doc Handling call messages
-spec handle_call(term(), {pid(), term()}, #state{}) ->
                         {reply, term(), #state{}} |
                         {reply, term(), #state{}, non_neg_integer()} |
                         {noreply, #state{}} |
                         {noreply, #state{}, non_neg_integer()} |
                         {stop, term(), term(), #state{}} |
                         {stop, term(), #state{}}.

handle_call({query_resource, Resource, States, Types}, _From, State) ->
    Result = do_query(Resource, States, Types, State),
    {reply, Result, State};
handle_call({get_lock, Lock, Pid, Meta}, _From, State) ->
    do_handle_call_exception(fun do_get_resource/5, [Lock, lock, Pid, Meta, State], State);
handle_call({get_lock_blocking, Lock, Pid, Meta, Timeout}, From, State) ->
    do_handle_call_exception(fun do_get_resource_blocking/7,
                             [Lock, lock, Pid, Meta, From, Timeout, State], State);
handle_call({lock_count, Lock}, _From, State) ->
    {reply, held_count(Lock, State), State};
handle_call({lock_limit_reached, Lock}, _From, State) ->
    do_handle_call_exception(fun do_lock_limit_reached/2, [Lock, State], State);
handle_call(lock_info, _From, State) ->
    do_handle_call_exception(fun do_get_type_info/2, [lock, State], State);
handle_call({lock_info, Lock}, _From, State) ->
    do_handle_call_exception(fun do_resource_info/2, [Lock, State], State);
handle_call({concurrency_limit, Lock}, _From, State) ->
    do_handle_call_exception(fun do_resource_limit/3, [lock, Lock, State], State);
handle_call({set_concurrency_limit, Lock, Limit, Kill}, _From, State) ->
    do_set_concurrency_limit(Lock, Limit, Kill, State);
handle_call({token_rate, Token}, _From, State) ->
    do_handle_call_exception(fun do_resource_limit/3, [token, Token, State], State);
handle_call(token_info, _From, State) ->
    do_handle_call_exception(fun do_get_type_info/2, [token, State], State);
handle_call({token_info, Token}, _From, State) ->
    do_handle_call_exception(fun do_resource_info/2, [Token, State], State);
handle_call({set_token_rate, Token, Rate}, _From, State) ->
    do_handle_call_exception(fun do_set_token_rate/3, [Token, Rate, State], State);
handle_call({get_token, Token, Pid, Meta}, _From, State) ->
    do_handle_call_exception(fun do_get_resource/5, [Token, token, Pid, Meta, State], State);
handle_call({get_token_blocking, Token, Pid, Meta, Timeout}, From, State) ->
    do_handle_call_exception(fun do_get_resource_blocking/7,
                             [Token, token, Pid, Meta, From, Timeout, State], State);
handle_call({head, Token, Offset, Count}, _From, State) ->
    Result = do_hist(head, Token, Offset, Count, State),
    {reply, Result, State};
handle_call({tail, Token, Offset, Count}, _From, State) ->
    Result = do_hist(tail, Token, Offset, Count, State),
    {reply, Result, State};
handle_call({ps, lock}, _From, State) ->
    Result = do_query(all, [given, blocked], [lock], State),
    {reply, Result, State};
handle_call({ps, token}, _From, State) ->
    Result = do_query(all, [given, blocked], [token], State),
    {reply, Result, State};
handle_call({ps, Resource}, _From, State) ->
    Result = do_query(Resource, [given, blocked], [token, lock], State),
    {reply, Result, State}.

%% @private
%% @doc Handling cast messages
-spec handle_cast(term(), #state{}) -> {noreply, #state{}} |
                                       {noreply, #state{}, non_neg_integer()} |
                                       {stop, term(), #state{}}.
handle_cast({enable, Resource}, State) ->
    do_handle_cast_exception(fun do_enable_resource/3, [Resource, true, State], State);
handle_cast({disable, Resource}, State) ->
    do_handle_cast_exception(fun do_enable_resource/3, [Resource, false, State], State);
handle_cast({disable, Lock, Kill}, State) ->
    do_handle_cast_exception(fun do_disable_lock/3, [Lock, Kill, State], State);
handle_cast(enable, State) ->
    State2 = State#state{enabled=true},
    {noreply, State2};
handle_cast(disable, State) ->
    State2 = State#state{enabled=false},
    {noreply, State2};
handle_cast(clear_history, State) ->
    State2 = do_clear_history(State),
    {noreply, State2}.

%% @private
%% @doc Handling all non call/cast messages
-spec handle_info(term(), #state{}) -> {noreply, #state{}} |
                                       {noreply, #state{}, non_neg_integer()} |
                                       {stop, term(), #state{}}.
%% Handle transfer of ETS table from table manager
handle_info({'ETS-TRANSFER', TableId, Pid, TableName}, State) ->
    lager:debug("table_mgr (~p) -> bg_mgr (~p) receiving ownership of TableId: ~p", [Pid, self(), TableId]),
    State2 = case TableName of
                 ?BG_INFO_ETS_TABLE -> State#state{info_table=TableId};
                 ?BG_ENTRY_ETS_TABLE -> State#state{entry_table=TableId}
             end,
    case {State2#state.info_table, State2#state.entry_table} of
        {undefined, _E} -> {noreply, State2};
        {_I, undefined} -> {noreply, State2};
        {_I, _E} ->
            %% Got both tables, we can proceed with reviving ourself
            State3 = validate_holds(State2),
            reschedule_token_refills(State3),
            {noreply, State3}
    end;
handle_info({'DOWN', Ref, _, _, _}, State) ->
    State2 = release_resource(Ref, State),
    {noreply, State2};
handle_info(sample_history, State) ->
    State2 = schedule_sample_history(State),
    State3 = do_sample_history(State2),
    {noreply, State3};
handle_info({blocked_timeout, Resource, From}, State) ->
    %% reply timeout to waiting caller and clear blocked queue.
    {noreply, do_reply_timeout(Resource, From, State)};
handle_info({refill_tokens, Type}, State) ->
    State2 = do_refill_tokens(Type, State),
    schedule_refill_tokens(Type, State2),
    {noreply, State2};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec terminate(term(), #state{}) -> term().
terminate(_Reason, _State) ->
    ok.

%% @private
%% @doc Convert process state when code is changed
-spec code_change(term() | {down, term()}, #state{}, term()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
%% @doc We must have just gotten the table data back after a crash/restart.
%%      Walk through the given resources and release any holds by dead processes.
%%      Assumes TableId is always valid (called only after transfer)
validate_holds(State=#state{entry_table=TableId}) ->
    [validate_hold(Obj, TableId) || Obj <- ets:match_object(TableId, {{given, '_'},'_'})],
    State.

%% @private
%% @doc If the given entry has no alive process associated with it,
%%      remove the hold from the ETS table. If it is alive, then we need
%%      to re-monitor it and update the table with the new ref.
validate_hold({Key,Entry}=Obj, TableId) when ?e_type(Entry) == lock ->
    case is_process_alive(?e_pid(Entry)) of
        true ->
            %% Still alive. Re-monitor and update table
            Ref = monitor(process, ?e_pid(Entry)),
            Entry2 = Entry#resource_entry{ref=Ref},
            ets:delete_object(TableId, Obj),
            ets:insert(TableId, {Key, Entry2});
        false ->
            %% Process is not alive - release the lock
            ets:delete_object(TableId, Obj)
    end;
validate_hold(_Obj, _TableId) -> %% tokens don't monitor processes
    ok.

%% @private
%% @doc Wrap a call, to a function with args, with a try/catch that handles
%%      thrown exceptions, namely '{unregistered, Resource}' and return the
%%      proper error response for a gen server cast.
do_handle_cast_exception(Function, Args, State) ->
    try apply(Function, Args)
    catch
        Error ->
            lager:error("Exception: ~p in function ~p", [Error, Function]),
            {noreply, State}
    end.

%% @private
%% @doc Wrap a call, to a function with args, with a try/catch that handles
%%      thrown exceptions, namely '{unregistered, Resource}' and return the
%%      failed error response for a gen server call.
do_handle_call_exception(Function, Args, State) ->
    try apply(Function, Args)
    catch
        Error ->
            lager:error("Exception: ~p in function ~p", [Error, Function]),
            {reply, Error, State}
    end.

%% @doc Throws {unregistered, Resource} for unknown Lock.
do_disable_lock(_Lock, _Kill, State) when ?NOT_TRANSFERED(State) ->
    {noreply, State};
do_disable_lock(Lock, Kill, State) ->
    Info = resource_info(Lock, State),
    enforce_type_or_throw(Lock, lock, Info),
    maybe_honor_limit(Kill, Lock, 0, State),
    do_enable_resource(Lock, false, State).

%% @doc Throws unregistered for unknown Token
do_set_token_rate(Token, Rate, State) ->
    try
        Info = resource_info(Token, State),
        OldRate = Info#resource_info.limit,
        enforce_type_or_throw(Token, token, Info),
        State2 = update_limit(Token, Rate, Info, State),
        schedule_refill_tokens(Token, State2),
        %% maybe reschedule blocked callers
        State3 = maybe_unblock_blocked(Token, State2),
        {reply, OldRate, State3}
    catch
        table_id_undefined ->
        %% This could go into a queue to be played when the transfer happens.
            {reply, undefined, State};
        {unregistered, Token} ->
            {reply, undefined, update_limit(Token, Rate, ?DEFAULT_TOKEN_INFO, State)};
        {badtype, _Token}=Error ->
            {reply, Error, State}
    end.

do_get_type_info(_Type, State) when ?NOT_TRANSFERED(State) ->
    %% Table not trasnferred yet.
    [];
do_get_type_info(Type, State) ->
    S = fun({R,_T,E,L}) -> {R,E,L} end,
    Resources = all_registered_resources(Type, State),
    Infos = [S(resource_info_tuple(Resource, State)) || Resource <- Resources],
    {reply, Infos, State}.

%% Returns empty if the ETS table has not been transferred to us yet.
do_resource_limit(lock, _Resource, State) when ?NOT_TRANSFERED(State) ->
    {reply, 0, State};
do_resource_limit(token, _Resource, State) when ?NOT_TRANSFERED(State) ->
    {reply, {0,0}, State};
do_resource_limit(_Type, Resource, State) ->
    Info = resource_info(Resource, State),
    Rate = ?resource_limit(Info),
    {reply, Rate, State}.

enforce_type_or_throw(Resource, Type, Info) ->
    case ?resource_type(Info) of
        Type -> ok;
        _Other -> throw({badtype, Resource})
    end.

do_set_concurrency_limit(Lock, Limit, Kill, State) ->
    try
        Info = resource_info(Lock, State),
        enforce_type_or_throw(Lock, lock, Info),
        OldLimit = limit(Info),
        State2 = update_limit(Lock, Limit, ?DEFAULT_LOCK_INFO, State),
        maybe_honor_limit(Kill, Lock, Limit, State2),
        {reply, OldLimit, State2}
    catch
        table_id_undefined ->
            %% This could go into a queue to be played when the transfer happens.
            {reply, 0, State};
        {unregistered, Lock} ->
            {reply, 0, update_limit(Lock, Limit, ?DEFAULT_LOCK_INFO, State)};
        {badtype, _Lock}=Error ->
            {reply, Error, State}
    end.

%% @doc Throws unregistered for unknown Lock
do_resource_info(Lock, State) ->
    {_R,_T,E,L} = resource_info_tuple(Lock, State),
    {reply, {E,L}, State}.

%% @doc Throws unregistered for unknown Lock
do_lock_limit_reached(Lock, State) ->
    Info = resource_info(Lock, State),
    enforce_type_or_throw(Lock, lock, Info),
    HeldCount = held_count(Lock, State),
    Limit = limit(Info),
    {reply, HeldCount >= Limit, State}.

%% @private
%% @doc Return the maximum allowed number of resources for the given
%%      info, which considers the type of resource, e.g. lock vs token.
limit(#resource_info{type=lock, limit=Limit}) -> Limit;
limit(#resource_info{type=token, limit={_Period,MaxCount}}) -> MaxCount.

%% @private
%% @doc Release the resource associated with the given reference. This is mostly
%%      meaningful for locks.
release_resource(_Ref, State) when ?NOT_TRANSFERED(State) ->
    State;
release_resource(Ref, State=#state{entry_table=TableId}) ->
    %% There should only be one instance of the object, but we'll zap all that match.
    Given = [Obj || Obj <- ets:match_object(TableId, {{given, '_'},'_'})],
    Matches = [Obj || {_Key,Entry}=Obj <- Given, ?e_ref(Entry) == Ref],
    [ets:delete_object(TableId, Obj) || Obj <- Matches],
    State.

maybe_honor_limit(true, Lock, Limit, State) ->
    Entries = all_given_entries(State),
    Held = [Entry || Entry <- Entries, ?e_type(Entry) == lock, ?e_resource(Entry) == Lock],
    case Limit < length(Held) of
        true ->
            {_Keep, Discards} = lists:split(Limit, Held),
            %% killing of processes will generate 'DOWN' messages and release the locks
            [erlang:exit(?e_pid(Discard), max_concurrency) || Discard <- Discards],
            ok;
        false ->
            ok
    end;
maybe_honor_limit(false, _LockType, _Limit, _State) ->
    ok.

held_count(Resource, State) ->
    length(resources_given(Resource, State)).

do_enable_resource(Resource, Enabled, State) ->
    Info = resource_info(Resource, State),
    State2 = update_resource_enabled(Resource, Enabled, Info, State),
    {noreply, State2}.

update_resource_enabled(Resource, Value, Default, State) ->
    update_resource_info(Resource,
                         fun(Info) -> Info#resource_info{enabled=Value} end,
                         Default#resource_info{enabled=Value},
                     State).

update_limit(Resource, Limit, Default, State) ->
    update_resource_info(Resource,
                         fun(Info) -> Info#resource_info{limit=Limit} end,
                         Default#resource_info{limit=Limit},
                         State).

update_resource_info(Resource, Fun, Default, State=#state{info_table=TableId}) ->
    Key = {info, Resource},
    NewInfo = case ets:lookup(TableId, Key) of
                  [] -> Default;
                  [{_Key,Info} | _Rest] -> Fun(Info)
              end,
    ets:insert(TableId, {Key, NewInfo}),
    State.

%% @doc Throws unregistered for unknown Resource
resource_info(_Resource, State) when ?NOT_TRANSFERED(State) ->
    throw(table_id_undefined);
resource_info(Resource, #state{info_table=TableId}) ->
    Key = {info,Resource},
    case ets:lookup(TableId, Key) of
        [] -> throw({unregistered, Resource});
        [{_Key,Info}] -> Info;
        [{_Key,_Info} | _Rest] -> throw({too_many_info_objects, Resource})
    end.

%% @doc Throws unregistered for unknown Resource
resource_info_tuple(Resource, State) ->
    Info = resource_info(Resource, State),
    {Resource, ?resource_type(Info), ?resource_enabled(Info), ?resource_limit(Info)}.


%% Possibly send replies to processes blocked on resources named Resource.
%% Returns new State.
give_available_resources(Resource, 0, Queue, State) ->
    %% no more available resources to give out
    update_blocked_queue(Resource, Queue, State);
give_available_resources(Resource, NumAvailable, Queue, State) ->
    case queue:out(Queue) of
        {empty, _Q} ->
            %% no more blocked entries
            update_blocked_queue(Resource, Queue, State);
        {{value, Entry}, Queue2} ->
            %% account for given resource
            State2 = give_resource(Entry, State),
            %% send reply to blocked caller, unblocking them.
            gen_server:reply(?e_from(Entry), ok),
            %% unblock next blocked in queue
            give_available_resources(Resource, NumAvailable-1, Queue2,State2)
    end.

%% @private
%% @doc
%% For the given type, check the current given count and if less
%% than the rate limit, give out as many tokens as are available
%% to callers on the blocked list. They need a reply because they
%% made a gen_server:call() that we have not replied to yet.
maybe_unblock_blocked(Resource, State) ->
    Entries = resources_given(Resource, State),
    Info = resource_info(Resource, State),
    MaxCount = limit(Info),
    PosNumAvailable = erlang:max(MaxCount - length(Entries), 0),
    Queue = blocked_queue(Resource, State),
    give_available_resources(Resource, PosNumAvailable, Queue, State).

schedule_timeout(Resource, From, Timeout) ->
    erlang:send_after(Timeout, self(), {blocked_timeout, Resource, From}),
    ok.

%% @private
%% @doc Send timeout reply to blocked caller, unblocking them.
%% And remove the matching entry from the blocked queue. We can find the
%% matching entry based on the 'From' since the caller can't block on more
%% than one call at a time.
do_reply_timeout(Resource, From, State) ->
    gen_server:reply(From, timeout),
    Queue = blocked_queue(Resource, State),
    Queue2 = queue:filter(fun(Entry) -> ?e_from(Entry) /= From end, Queue),
    update_blocked_queue(Resource, Queue2, State).

%% @private
%% @doc
%% Get existing token type info from ETS table and schedule all for refill.
%% This is needed because we just reloaded our saved persisent state data
%% after a crash. Assumes table is available. Called only after Transfer.
reschedule_token_refills(State) ->
    Tokens = all_registered_resources(token, State),
    [schedule_refill_tokens(Token, State) || Token <- Tokens].
 
%% Schedule a timer event to refill tokens of given type
schedule_refill_tokens(_Token, State) when ?NOT_TRANSFERED(State) ->
    ok;
schedule_refill_tokens(Token, State) ->
    case ?resource_limit(resource_info(Token, State)) of
        undefined ->
            ok;
        {Period, _Count} ->
            erlang:send_after(Period, self(), {refill_tokens, Token})
    end.

%% Schedule a timer event to snapshot the current history
schedule_sample_history(State=#state{window_interval=Interval}) ->
    TRef = erlang:send_after(Interval, self(), sample_history),
    State#state{window_tref=TRef}.

%% @doc Update the "limit" history stat for all registered resources into current window.
update_stat_all_limits(State) ->
    lists:foldl(fun({Resource, Info}, S) ->
                        increment_stat_limit(Resource, ?resource_limit(Info), S)
                end,
                State,
                all_resource_info(State)).

do_sample_history(State) ->
    %% Update window with current limits before copying it
    State2 = update_stat_all_limits(State),
    %% Move the current window of measurements onto the history queues.
    %% Trim queue down to ?BG_DEFAULT_KEPT_SAMPLES if too big now.
    Queue2 = queue:in(State2#state.window, State2#state.history),
    Trimmed = case queue:len(Queue2) > ?BG_DEFAULT_KEPT_SAMPLES of
                  true ->
                      {_Discarded, Rest} = queue:out(Queue2),
                      Rest;
                  false ->
                      Queue2
              end,
    EmptyWindow = orddict:new(),
    State2#state{window=EmptyWindow, history=Trimmed}.

update_stat_window(Resource, Fun, Default, State=#state{window=Window}) ->
    NewWindow = orddict:update(Resource, Fun, Default, Window),
    State#state{window=NewWindow}.

resources_given(Resource, #state{entry_table=TableId}) ->
    [Entry || {{given,_R},Entry} <- ets:match_object(TableId, {{given, Resource},'_'})].

%%    Key = {given, Resource},
%%    [Given || {_K,Given} <- ets:lookup(TableId, Key)].

%% @private
%% @doc Add a Resource Entry to the "given" table. Here, we really do want
%% to allow multiple entries because each Resource "name" can be given multiple
%% times.
add_given_entry(Resource, Entry, TableId) ->
    Key = {given, Resource},
    ets:insert(TableId, {Key, Entry}).

remove_given_entries(Resource, #state{entry_table=TableId}) ->
    Key = {given, Resource},
    ets:delete(TableId, Key).

%% @private
%% @doc Add a resource queue entry to our given set.
give_resource(Entry, State=#state{entry_table=TableId}) ->
    Resource = ?e_resource(Entry),
    Type = ?e_type(Entry),
    add_given_entry(Resource, Entry#resource_entry{state=given}, TableId),
    %% update given stats
    increment_stat_given(Resource, Type, State).

%% @private
%% @doc Add Resource to our given set.
give_resource(Resource, Type, Pid, Ref, Meta, State) ->
    From = undefined,
    Entry = ?RESOURCE_ENTRY(Resource, Type, Pid, Meta, From, Ref, given),
    give_resource(Entry, State).

-spec try_get_resource(boolean(), bg_resource(), bg_resource_type(), pid(), [{atom(), any()}], #state{}) ->
                              {max_concurrency, #state{}}
                                  | {ok, #state{}}
                                  | {{ok, reference()}, #state{}}.
try_get_resource(false, _Resource, _Type, _Pid, _Meta, State) ->
    {max_concurrency, State};
try_get_resource(true, Resource, Type, Pid, Meta, State) ->
    case Type of
        token ->
            Ref = random_bogus_ref(),
            {ok, give_resource(Resource, Type, Pid, Ref, Meta, State)};
        lock ->
            Ref = monitor(process, Pid),
            {{ok,Ref}, give_resource(Resource, Type, Pid, Ref, Meta, State)}
    end.

%% @private
%% @doc reply now if resource is available. Returns max_concurrency
%%      if resource not available or globally or specifically disabled.
-spec do_get_resource(bg_resource(), bg_resource_type(), pid(), [{atom(), any()}], #state{}) ->
                             {reply, max_concurrency, #state{}}
                                 | {reply, {ok, #state{}}}
                                 | {reply, {{ok, reference()}, #state{}}}.
do_get_resource(_Resource, _Type, _Pid, _Meta, State) when ?NOT_TRANSFERED(State) ->
    %% Table transfer has not occurred yet. Reply "max_concurrency" so that callers
    %% will try back later, hopefully when we have our table back.
    {reply, max_concurrency, State};
do_get_resource(_Resource, _Type, _Pid, _Meta, State=#state{enabled=false}) ->
    {reply, max_concurrency, State};
do_get_resource(Resource, Type, Pid, Meta, State) ->
    Info = resource_info(Resource, State),
    enforce_type_or_throw(Resource, Type, Info),
    Enabled = ?resource_enabled(Info),
    Limit = limit(Info),
    Given  = length(resources_given(Resource, State)),
    {Result, State2} = try_get_resource(Enabled andalso not (Given >= Limit),
                                        Resource, Type, Pid, Meta, State),
    {reply, Result, State2}.

%% @private
%% @doc
%% reply now if available or reply later if en-queued. Call returns even if we can't
%% get the resource now, but 'noreply' indicates that calling process will block until
%% we forward the reply later.
do_get_resource_blocking(Resource, Type, Pid, Meta, From, Timeout, State) ->
    case do_get_resource(Resource, Type, Pid, Meta, State) of
        {reply, max_concurrency, _State2} ->
            {noreply, enqueue_request(Resource, Type, Pid, Meta, From, Timeout, State)};
        Reply ->
            Reply
    end.

%% @private
%% @doc Replace the current "blocked entries" queue for the specified Resource.
update_blocked_queue(Resource, Queue, State=#state{entry_table=TableId}) ->
    Key = {blocked, Resource},
    Object = {Key, Queue},
    %% replace existing queue. Must delete existing one since we're using a bag table
    ets:delete(TableId, Key),
    ets:insert(TableId, Object),
    State.

%% @private
%% @doc Return the queue of blocked resources named 'Resource'.
blocked_queue(Resource, #state{entry_table=TableId}) ->
    Key = {blocked, Resource},
    case ets:lookup(TableId, Key) of
        [] -> queue:new();
        [{Key,Queue} | _Rest] -> Queue
    end.

%% @private
%% @doc This should create a unique reference every time it's called; and should
%%      not repeat across process restarts since our ETS table lives across process
%%      lifetimes. This is needed to create unique entries in the "given" table.
random_bogus_ref() ->
    make_ref().

%% @private
%% @doc Put a resource request on the blocked queue. We'll reply later when resources
%% of that type become available.
enqueue_request(Resource, Type, Pid, Meta, From, Timeout, State) ->
    OldQueue = blocked_queue(Resource, State),
    Ref = case Type of
              token -> random_bogus_ref();
              lock -> monitor(process, Pid)
          end,
    NewQueue = queue:in(?RESOURCE_ENTRY(Resource, Type, Pid, Meta, From, Ref, blocked), OldQueue),
    schedule_timeout(Resource, From, Timeout),
    %% update blocked stats
    State2 = increment_stat_blocked(Resource, State),
    %% Put new queue back in state
    update_blocked_queue(Resource, NewQueue, State2).

all_resource_info(#state{info_table=TableId}) ->
    [{Resource, Info} || {{info, Resource}, Info} <- ets:match_object(TableId, {{info, '_'},'_'})].

all_registered_resources(Type, #state{info_table=TableId}) ->
    [Resource || {{info, Resource}, Info} <- ets:match_object(TableId, {{info, '_'},'_'}),
                 ?resource_type(Info) == Type].

all_given_entries(#state{entry_table=TableId}) ->
    %% multiple entries per resource type, i.e. uses the "bag"
    [Entry || {{given, _Resource}, Entry} <- ets:match_object(TableId, {{given, '_'},'_'})].

all_blocked_queues(#state{entry_table=TableId}) ->
    %% there is just one queue per resource type. More like a "set". The queue is in the table!
    [Queue || {{blocked, _Resource}, Queue} <- ets:match_object(TableId, {{blocked, '_'},'_'})].

format_entry(Entry) ->
    #bg_stat_live
        {
          resource = ?e_resource(Entry),
          type = ?e_type(Entry),
          consumer = ?e_pid(Entry),
          meta = ?e_meta(Entry),
          state = ?e_state(Entry)
        }.

fmt_live_entries(Entries) ->
    [format_entry(Entry) || Entry <- Entries].

%% States :: [given | blocked], Types :: [lock | token]
do_query(_Resource, _States, _Types, State) when ?NOT_TRANSFERED(State) ->
    %% Table hasn't been transfered yet.
    [];
do_query(all, States, Types, State) ->
    E1 = case lists:member(given, States) of
             true ->
                 Entries = all_given_entries(State),
                 lists:flatten([Entry || Entry <- Entries,
                                         lists:member(?e_type(Entry), Types)]);
             false ->
                 []
         end,
    E2 = case lists:member(blocked, States) of
             true ->
                 Queues = all_blocked_queues(State),
                 E1 ++ lists:flatten(
                         [[Entry || Entry <- queue:to_list(Q),
                                    lists:member(?e_type(Entry), Types)] || Q <- Queues]);
             false ->
                 E1
         end,
    fmt_live_entries(E2);
do_query(Resource, States, Types, State) ->
    E1 = case lists:member(given, States) of
             true ->
                 Entries = resources_given(Resource, State),
                 [Entry || Entry <- Entries, lists:member(?e_type(Entry), Types)];
             false ->
                 []
         end,
    E2 = case lists:member(blocked, States) of
             true ->
                 %% Oh Erlang, why is your scoping so messed up?
                 Entries2 = queue:to_list(blocked_queue(Resource, State)),
                 E1 ++ [Entry || Entry <- Entries2, lists:member(?e_type(Entry), Types)];
             false ->
                 E1
         end,
    fmt_live_entries(E2).

%% @private
%% @doc Token refill timer event handler.
%%   Capture stats of what was given in the previous period,
%%   Clear all tokens of this type from the given set,
%%   Unblock blocked processes if possible.
do_refill_tokens(Token, State) ->
    State2 = increment_stat_refills(Token, State),
    remove_given_entries(Token, State),
    maybe_unblock_blocked(Token, State2).

default_refill(Token, State) ->
    Limit = limit(resource_info(Token, State)),
    ?BG_DEFAULT_STAT_HIST#bg_stat_hist{type=token, refills=1, limit=Limit}.

default_given(Token, Type, State) ->
    Limit = limit(resource_info(Token, State)),
    ?BG_DEFAULT_STAT_HIST#bg_stat_hist{type=Type, given=1, limit=Limit}.

increment_stat_limit(_Resource, undefined, State) ->
    State;
increment_stat_limit(Resource, Limit, State) ->
    {Type, Count} = case Limit of
                        {_Period, C} -> {token, C};
                        N -> {lock, N}
                    end,
    update_stat_window(Resource,
                       fun(Stat) -> Stat#bg_stat_hist{limit=Count} end,
                       ?BG_DEFAULT_STAT_HIST#bg_stat_hist{type=Type, limit=Count},
                       State).

increment_stat_refills(Token, State) ->
    update_stat_window(Token,
                       fun(Stat) -> Stat#bg_stat_hist{refills=1+Stat#bg_stat_hist.refills} end,
                       default_refill(Token, State),
                       State).

increment_stat_given(Token, Type, State) ->
    update_stat_window(Token,
                       fun(Stat) -> Stat#bg_stat_hist{given=1+Stat#bg_stat_hist.given} end,
                       default_given(Token, Type, State),
                       State).

increment_stat_blocked(Token, State) ->
    Limit = limit(resource_info(Token, State)),
    update_stat_window(Token,
                       fun(Stat) -> Stat#bg_stat_hist{blocked=1+Stat#bg_stat_hist.blocked} end,
                       ?BG_DEFAULT_STAT_HIST#bg_stat_hist{blocked=1, limit=Limit},
                       State).

%% erase saved history
do_clear_history(State=#state{window_tref=TRef}) ->
    erlang:cancel_timer(TRef),
    State2 = State#state{history=queue:new()},
    schedule_sample_history(State2).

%% Return stats history from head or tail of stats history queue
do_hist(_End, _Resource, _Offset, _Count, State) when ?NOT_TRANSFERED(State) ->
    [];
do_hist(End, Resource, Offset, Count, State) when Offset < 0 ->
    do_hist(End, Resource, 0, Count, State);
do_hist(_End, _Resource, _Offset, Count, _State) when Count =< 0 ->
    [];
do_hist(End, Resource, Offset, Count, #state{history=HistQueue}) ->
    QLen = queue:len(HistQueue),
    First = max(1, case End of
                       head -> min(Offset+1, QLen);
                       tail -> QLen - Offset + 1
                   end),
    Last = min(QLen, max(First + Count - 1, 1)),
    H = case segment_queue(First, Last, HistQueue) of
            empty -> [];
            {ok, Hist } -> 
                case Resource of
                    all ->
                        StatsDictList = queue:to_list(Hist),
                        [orddict:to_list(Stat) || Stat <- StatsDictList];
                    _T  ->
                        [[{Resource, stat_window(Resource, StatsDict)}]
                         || StatsDict <- queue:to_list(Hist), stat_window(Resource, StatsDict) =/= undefined]
                end
        end,
    %% Remove empty windows
    lists:filter(fun(S) -> S =/= [] end, H).

segment_queue(First, Last, _Q) when Last < First ->
    empty;
segment_queue(First, Last, Queue) ->
    QLen = queue:len(Queue),
    case QLen >= Last andalso QLen > 0 of
        true ->
            %% trim off extra tail, then trim head
            Front = case QLen == Last of
                        true -> Queue;
                        false ->
                            {QFirst, _QRest} = queue:split(Last, Queue),
                            QFirst
                    end,
            case First == 1 of
                true -> {ok, Front};
                false ->
                    {_Skip, Back} = queue:split(First-1, Front),
                    {ok, Back}
            end;
        false ->
            %% empty
            empty
    end.
 
%% @private
%% @doc Get stat history for given token type from sample set
-spec stat_window(bg_resource(), orddict:orddict()) -> bg_stat_hist().
stat_window(Resource, Window) ->
    case orddict:find(Resource, Window) of
        error -> undefined;
        {ok, StatHist} -> StatHist
    end.
