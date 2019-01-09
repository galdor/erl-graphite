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

-module(graphite).

-export([send_point/2, prefix_point/2]).
-export([serialize_point/1, serialize_points/1]).

-export_type([point/0]).

-record(point, {key :: string(),
                timestamp :: integer(),
                value :: number()}).
-opaque point() :: #point{}.

-spec send_point(string(), number()) -> term().
send_point(Key, Value) ->
  Now = erlang:system_time(second),
  Point = #point{key = Key, timestamp = Now, value = Value},
  gen_server:call(graphite_client, {enqueue_point, Point}).

-spec prefix_point(point(), string()) -> point().
prefix_point(Point, Prefix) ->
  Key = Prefix ++ Point#point.key,
  Point#point{key = Key}.

-spec serialize_points(list(point())) -> iodata().
serialize_points(Points) ->
  lists:map(fun serialize_point/1, Points).

-spec serialize_point(point()) -> iodata().
serialize_point(Point) ->
  ValueString = io_lib:format("~p", [Point#point.value]),
  TimestampString = integer_to_list(Point#point.timestamp),
  [Point#point.key, $\s, ValueString, $\s, TimestampString, $\n].
