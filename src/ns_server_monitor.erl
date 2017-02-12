%% @author Couchbase <info@couchbase.com>
%% @copyright 2017 Couchbase, Inc.
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

-module(ns_server_monitor).

-include("ns_common.hrl").

-export([start_link/0]).
-export([get_nodes/0,
         annotate_status/1,
         analyze_status/2,
         is_node_down/1]).
-export([init/0, handle_call/4, handle_cast/3, handle_info/3]).

start_link() ->
    health_monitor:start_link(?MODULE).

init() ->
    health_monitor:common_init(?MODULE, with_refresh).

handle_call(get_nodes, _From, Statuses, _Nodes) ->
    RV = dict:map(
           fun (_Node, {recv_ts, RecvTS}) ->
                   health_monitor:is_active(RecvTS);
               (_Node, Status) ->
                   Status
           end, Statuses),
    {reply, RV};

handle_call(Call, From, Statuses, _Nodes) ->
    ?log_warning("Unexpected call ~p from ~p when in state:~n~p",
                 [Call, From, Statuses]),
    {reply, nack}.

handle_cast(Cast, Statuses, _NodesWanted) ->
    ?log_warning("Unexpected cast ~p when in state:~n~p", [Cast, Statuses]),
    noreply.

handle_info(refresh, _Statuses, NodesWanted) ->
    health_monitor:send_heartbeat(?MODULE, NodesWanted),
    noreply;

handle_info(Info, Statuses, _NodesWanted) ->
    ?log_warning("Unexpected message ~p when in state:~n~p", [Info, Statuses]),
    noreply.

%% APIs
get_nodes() ->
    gen_server:call(?MODULE, get_nodes).

annotate_status(empty) ->
    {recv_ts, erlang:now()}.

is_node_down(needs_attention) ->
    {true, "Cluster manager is down."};
is_node_down(_) ->
    false.

analyze_status(Node, AllNodes) ->
    %% AllNodes contains each node's view of every other node in the
    %% cluster.
    %% Find which node's have Node as active and which don't.
    {Actives, Inactives} = lists:foldl(
                             fun (OtherNodeView, Accs) ->
                                     analyze_node_view(OtherNodeView,
                                                       Node,
                                                       Accs)
                             end, {[], []}, AllNodes),
    case Inactives of
        [] ->
            %% Things are healthy if all other node's say Node is active.
            healthy;
        _ ->
            case Actives of
                [] ->
                    unhealthy;
                _ ->
                    %% If some nodes say Node is active and other's
                    %% don't then it is potentially a network
                    %% partition or communication is flaky.
                    {potential_network_partition, lists:sort(Inactives)}
            end
    end.

%% Internal functions
analyze_node_view({_OtherNode, inactive, _}, _, Accs) ->
    %% Consider OtherNode's view  only if it itself is active.
    Accs;
analyze_node_view({OtherNode, _, NodeView}, Node, {Active, Inactive}) ->
    Status = proplists:get_value(Node, NodeView, []),
    case proplists:get_value(ns_server, Status, unknown) of
        active ->
            {[OtherNode | Active], Inactive};
        _ ->
            {Active, [OtherNode | Inactive]}
    end.
