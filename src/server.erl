-module(server).
-export([start_link/0, loop/1]).

start_link() ->
    Pid = spawn_link(fun() -> register(server, self()), start() end),
    {ok, Pid}.

start() ->
    {ok, Sock} = gen_tcp:listen(6667, [list, {reuseaddr, true}]),
    loop(Sock).

loop(Sock) ->
    case gen_tcp:accept(Sock) of
    {ok, ClientSock} ->
        {ok, Pid} = client_sup:start_child(ClientSock),
        ok = gen_tcp:controlling_process(ClientSock, Pid),
        ok = inet:setopts(ClientSock, [{active, true}, {packet, line}])
    end,
    ?MODULE:loop(Sock).
