-module(client_sup).
-behavior(supervisor).
-export([start_link/0, start_child/1, init/1]).
-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_child(Socket) ->
    {ok, Peername} = inet:peername(Socket),
    supervisor:start_child(?SERVER, {Peername, {client, start_link, [Socket]}, temporary, 1000, worker, [client]}).

init([]) ->
    {ok, {{one_for_one, 1, 1000}, []}}.
