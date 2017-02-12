%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc
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
-module(ns_child_ports_sup).

-behavior(supervisor).

-export([start_link/0, set_dynamic_children/1,
         send_command/2,
         create_ns_server_supervisor_spec/0]).

-export([init/1,
         restart_port/1,
         current_ports/0, find_port/1]).

-include("ns_common.hrl").

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 100, 10}, []}}.

send_command(PortName, Command) ->
    try
        do_send_command(PortName, Command)
    catch T:E ->
            ?log_error("Failed to send command ~p to port ~p due to ~p:~p. Ignoring...~n~p",
                       [Command, PortName, T, E, erlang:get_stacktrace()]),
            {T, E}
    end.

find_port(PortName) ->
    Childs = supervisor:which_children(?MODULE),
    [Pid] = [Pid || {Id, Pid, _, _} <- Childs,
                    Pid =/= undefined,
                    element(1, Id) =:= PortName],
    Pid.

do_send_command(PortName, Command) ->
    Pid = find_port(PortName),
    Pid ! {send_to_port, Command},
    {ok, Pid}.

-spec set_dynamic_children([any()]) -> pid().
set_dynamic_children(NCAOs) ->
    RequestedIds = [sanitize(NCAO) || NCAO <- NCAOs],
    CurrentIds = [erlang:element(1, C) || C <- supervisor:which_children(?MODULE)],
    IdsToTerminate = CurrentIds -- RequestedIds,

    RequestedIdsParams = lists:zip(RequestedIds, NCAOs),
    IdsParamsToLaunch = lists:filter(fun ({Id, _NCAO}) ->
                                             not lists:member(Id, CurrentIds)
                                     end, RequestedIdsParams),

    PidBefore = erlang:whereis(?MODULE),

    lists:foreach(fun(Id) ->
                          terminate_port(Id)
                  end,
                  IdsToTerminate),
    lists:foreach(fun({Id, NCAO}) ->
                          launch_port(Id, NCAO)
                  end,
                  IdsParamsToLaunch),

    PidAfter = erlang:whereis(?MODULE),
    PidBefore = PidAfter.

sanitize_value(Value) ->
    crypto:hash(sha256, term_to_binary(Value)).

sanitize(Struct) ->
    misc:rewrite_tuples(
      fun ({"MOXI_SASL_PLAIN_PWD", V}) ->
              {stop, {"MOXI_SASL_PLAIN_PWD", sanitize_value(V)}};
          ({"CBAUTH_REVRPC_URL", V}) ->
              {stop, {"CBAUTH_REVRPC_URL", sanitize_value(V)}};
          (Other) ->
              {continue, Other}
      end, Struct).

launch_port(Id, NCAO) ->
    ?log_info("supervising port: ~p", [Id]),
    {ok, _C} = supervisor:start_child(?MODULE,
                                      create_child_spec(Id, NCAO)).

create_ns_server_supervisor_spec() ->
    {ErlCmd, NSServerArgs, NSServerOpts} = child_erlang:open_port_args(),

    Options = case misc:get_env_default(ns_server, dont_suppress_stderr_logger, false) of
                  true ->
                      [ns_server_no_stderr_to_stdout | NSServerOpts];
                  _ ->
                      NSServerOpts
              end,

    NCAO = {ns_server, ErlCmd, NSServerArgs, Options},
    create_child_spec(NCAO, NCAO).

create_child_spec(Id, {Name, Cmd, Args, Opts}) ->
    %% wrap parameters into function here to protect passwords
    %% that could be inside those parameters from being logged
    restartable:spec(
      {Id,
       {supervisor_cushion, start_link,
        [Name, 5000, infinity, ns_port_server, start_link,
         [fun() -> {Name, Cmd, Args, Opts} end]]},
       permanent, 86400000, worker,
       [ns_port_server]}).

terminate_port(Id) ->
    ?log_info("unsupervising port: ~p", [Id]),
    ok = supervisor:terminate_child(?MODULE, Id),
    ok = supervisor:delete_child(?MODULE, Id).

restart_port(Id) ->
    ?log_info("restarting port: ~p", [Id]),
    {ok, _} = restartable:restart(?MODULE, Id).

current_ports() ->
    % Children will look like...
    %   [{memcached,<0.77.0>,worker,[ns_port_server]},
    %    {ns_port_init,undefined,worker,[]}]
    %
    % Or possibly, if a child died, like...
    %   [{memcached,undefined,worker,[ns_port_server]},
    %    {ns_port_init,undefined,worker,[]}]
    %
    Children = supervisor:which_children(?MODULE),
    [NCAO || {NCAO, Pid, _, _} <- Children,
             Pid /= undefined].
