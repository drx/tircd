-module(server_sup).
-behavior(supervisor).
-export([start_link/0, init/1]).
-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    Server = {server, {server, start_link, []}, permanent, 2000, worker, [server]},
    ClientSup = {client_sup, {client_sup, start_link, []}, permanent, 2000, supervisor, [client_sup]},
    {ok, {{one_for_one, 1, 1000}, [Server, ClientSup]}}.
