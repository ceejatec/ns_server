%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% Run a set of processes per bucket

-module(ns_bucket_sup).

-behaviour(supervisor).

-include("ns_common.hrl").

-export([start_link/0, subscribe_on_config_events/0]).
-export([ignore_if_not_couchbase_bucket/2]).

-export([init/1]).


%% API
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

ignore_if_not_couchbase_bucket(BucketName, Body) ->
    case ns_bucket:get_bucket(BucketName) of
        not_present ->
            ignore;
        {ok, BucketConfig} ->
            case proplists:get_value(type, BucketConfig) of
                memcached ->
                    ignore;
                _ ->
                    Body(BucketConfig)
            end
    end.

%% supervisor callbacks

-define(SUBSCRIPTION_SPEC_NAME, buckets_observing_subscription).

init([]) ->
    SubscriptionChild = {?SUBSCRIPTION_SPEC_NAME,
                         {?MODULE, subscribe_on_config_events, []},
                         permanent, 1000, worker, []},
    {ok, {{one_for_one, 3, 10},
          [SubscriptionChild]}}.

%% Internal functions

ns_config_event_handler_body({buckets, _}) ->
    submit_update();
ns_config_event_handler_body({node, Node, membership}) when Node =:= node() ->
    submit_update();
ns_config_event_handler_body({node, Node, services}) when Node =:= node() ->
    submit_update();
ns_config_event_handler_body(_) ->
    ok.

submit_update() ->
    work_queue:submit_work(ns_bucket_worker, fun update_children/0).

subscribe_on_config_events() ->
    Pid = ns_pubsub:subscribe_link(
            ns_config_events,
            fun ns_config_event_handler_body/1),
    submit_update(),
    {ok, Pid}.

update_children() ->
    Config = ns_config:get(),
    Buckets = ns_bucket:get_buckets(Config),

    NewSpecs = lists:flatmap(
                 fun ({Bucket, BucketConfig}) ->
                         BucketNodes = ns_bucket:bucket_nodes(BucketConfig),
                         HaveBucket = lists:member(node(), BucketNodes),

                         case HaveBucket of
                             true ->
                                 [{{single_bucket_kv_sup, Bucket},
                                   {single_bucket_kv_sup, start_link, [Bucket]},
                                   permanent, infinity, supervisor,
                                   [single_bucket_kv_sup]}];
                             false ->
                                 []
                         end
                 end, Buckets),

    NewIds = [element(1, X) || X <- NewSpecs],
    OldSpecs = supervisor:which_children(?MODULE),
    RunningIds = [element(1, X) || X <- OldSpecs],
    ToStart = NewIds -- RunningIds,
    ToStop = (RunningIds -- NewIds) -- [?SUBSCRIPTION_SPEC_NAME],

    lists:foreach(fun (StartId) ->
                          Tuple = lists:keyfind(StartId, 1, NewSpecs),
                          true = is_tuple(Tuple),
                          ?log_debug("Starting new child: ~p~n",
                                     [Tuple]),
                          {ok, _} = supervisor:start_child(?MODULE, Tuple)
                  end, ToStart),

    lists:foreach(fun (StopId) ->
                          Tuple = lists:keyfind(StopId, 1, OldSpecs),
                          true = is_tuple(Tuple),
                          ?log_debug("Stopping child for dead bucket: ~p~n",
                                     [Tuple]),
                          TimeoutPid =
                              diag_handler:arm_timeout(
                                30000,
                                fun (_) ->
                                        ?log_debug("Observing slow bucket supervisor stop request for ~p",
                                                   [Tuple]),
                                        timeout_diag_logger:log_diagnostics({slow_bucket_stop, Tuple})
                                end),
                          try
                              ok = supervisor:terminate_child(?MODULE, StopId)
                          after
                              diag_handler:disarm_timeout(TimeoutPid)
                          end,
                          ok = supervisor:delete_child(?MODULE, StopId)
                  end, ToStop).
