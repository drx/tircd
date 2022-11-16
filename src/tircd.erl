-module(tircd).
-behavior(application).
-export([start/2, stop/1]).

-include("tircd.hrl").

start(_Type, _StartArgs) ->
    mnesia:create_schema([node()]),
    mnesia:start(),
    mnesia:create_table(client, [{type, set}, {attributes, record_info(fields, client)}]),
    mnesia:create_table(channel_modes, [{disc_copies, [node()]}, {type, set}, {attributes, record_info(fields, channel_modes)}]),
    mnesia:create_table(channel_user, [{type, bag}, {attributes, record_info(fields, channel_user)}]),
    server_sup:start_link().

stop(_State) ->
    mnesia:delete_table(client),
    mnesia:delete_table(channel_user),
    ok.
