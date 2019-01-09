%% Copyright (c) 2019 Nicolas Martyanoff <khaelin@gmail.com>.
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
%% REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
%% AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
%% INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
%% LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
%% OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
%% PERFORMANCE OF THIS SOFTWARE.

-module(graphite_client).

-include_lib("kernel/include/logger.hrl").

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, terminate/2,
         handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {host :: inet:hostname(),
                port :: inet:port_number(),
                prefix :: string(),
                socket :: undefined | inet:socket(),
                queue = [] :: list(graphite:point()),
                queue_length = 0 :: integer(),
                max_queue_length :: undefined | pos_integer(),
                send_timer :: timer:tref(),
                backoff :: backoff:backoff()}).
-type state() :: #state{}.

start_link(Args) ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

init(_Args) ->
  Env = fun (Key, Default) ->
            application:get_env(graphite, Key, Default)
        end,
  logger:update_process_metadata(#{domain => [graphite]}),
  Backoff = backoff:type(backoff:init(1000, 60000), jitter),
  {ok, SendTimer} = timer:send_interval(1000, send_points),
  State = #state{host = Env(host, "localhost"),
                 port = Env(port, 2003),
                 prefix = Env(prefix, ""),
                 max_queue_length = Env(max_queue_length, 10000),
                 send_timer = SendTimer,
                 backoff = Backoff},
  self() ! connect,
  {ok, State}.

terminate(Reason, State) when
    State#state.socket /= undefined ->
  gen_tcp:close(State #state.socket),
  terminate(Reason, State#state{socket = undefined});
terminate(_Reason, State) ->
  timer:cancel(State#state.send_timer),
  ok.

handle_call({enqueue_point, _Point}, _From, State) when
    State#state.queue_length >= State#state.max_queue_length ->
  {reply, queue_full, State};
handle_call({enqueue_point, Point}, _From, State) ->
  Point2 = graphite:prefix_point(Point, State#state.prefix),
  {reply, ok, State#state{queue = [Point2 | State#state.queue],
                          queue_length = State#state.queue_length + 1}};

handle_call(Request, _From, State) ->
  {noreply, State}.

handle_cast(Request, State) ->
  {noreply, State}.

handle_info(connect, State) ->
  Host = State#state.host,
  Port = State#state.port,
  ?LOG_INFO("connecting to ~s:~B", [Host, Port]),
  case gen_tcp:connect(Host, Port, []) of
    {ok, Socket} ->
      ?LOG_INFO("connection established"),
      {_, Backoff} = backoff:succeed(State#state.backoff),
      {noreply, State#state{socket = Socket, backoff = Backoff}};
    {error, Reason} ->
      ?LOG_ERROR("connection failed: ~p", [Reason]),
      {_, Backoff} = backoff:fail(State#state.backoff),
      {noreply, schedule_connection(State#state{backoff = Backoff})}
  end;

handle_info(send_points, State) when
    State#state.socket /= undefined andalso length(State#state.queue) > 0 ->
  PointsData = graphite:serialize_points(State#state.queue),
  case gen_tcp:send(State#state.socket, PointsData) of
    ok ->
      {noreply, State#state{queue = [], queue_length = 0}};
    {error, Reason} ->
      ?LOG_ERROR("cannot send points: ~p", [Reason]),
      ok = gen_tcp:close(State#state.socket),
      {noreply, schedule_connection(State#state{socket = undefined})}
  end;
handle_info(send_points, State) ->
  {noreply, State};

handle_info({tcp_closed, _}, State) ->
  ?LOG_INFO("connection closed"),
  {noreply, schedule_connection(State)};

handle_info(Info, State) ->
  {noreply, State}.

-spec schedule_connection(state()) -> state().
schedule_connection(State) ->
  timer:send_after(backoff:get(State#state.backoff), self(), connect),
  State.
