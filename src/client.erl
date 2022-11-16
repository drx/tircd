-module(client).
-behavior(gen_server).
-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {socket, nick = undefined}).

-include("tircd.hrl").

-define(RPL_ENDOFWHO, 315).
-define(RPL_NOTOPIC, 331).
-define(RPL_WHOREPLY, 352).
-define(RPL_NAMEREPLY, 353).
-define(RPL_ENDOFNAMES, 366).
-define(RPL_MOTD, 372).
-define(RPL_MOTDSTART, 375).
-define(RPL_ENDOFMOTD, 376).
-define(ERR_NOSUCHCHANNEL, 403).
-define(ERR_NICKNAMEINUSE, 433).

-define(SERVER_NAME, "server_name").
-define(USER_DATA, [Username, Hostname, Servername, Realname]).
-define(HOST_MASK, Nick ++ "!" ++ Username ++ "@" ++ Servername).

start_link(Sock) ->
    gen_server:start_link(?MODULE, [Sock], []).

init([Sock]) ->
    State = #state{socket = Sock},
    send(State, ?SERVER_NAME, "NOTICE", ["AUTH", "*** What is your nick?"]),
    {ok, State}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({send, From, Command, Params}, State) ->
    send(State, From, Command, Params),
    {noreply, State}.

handle_info({tcp, Socket, Data}, #state{socket = Socket} = State) ->
    Lines = string:tokens(Data, "\r\n"),
    lists:foldl(fun(Line, {noreply, State2}) -> case (catch handle_data(Line, State2)) of
        quit ->
          {stop, normal, State2};
        #state{} = NewState ->
          {noreply, NewState};
        X ->
          {noreply, State}
        end;
        (_Line, R) -> R
        end, {noreply, State}, Lines);

handle_info({tcp_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, normal, State}.

terminate(Reason, #state{nick = Nick} = State) ->
    case Reason of
        {'EXIT', {Why, _}} -> Message = atom_to_list(Why);
        normal -> Message = "Closed";
        _ -> Message = "Error"
    end,
    F = fun() ->
          mnesia:write_lock_table(channel_user),
          mnesia:write_lock_table(client),
          Channels = mnesia:select(channel_user, [{#channel_user{client = Nick, channel = '$1'}, [], ['$1']}]),
          ChannelNicks =
          [[Nick1
            || #channel_user{client = Nick1} <- mnesia:read({channel_user, Channel})]
           || Channel <- Channels],
          ChannelNicks1 = lists:merge(ChannelNicks),
          Pids = lists:map(
               fun(Nick1) ->
                   [#client{pid = Pid}] = mnesia:read({client, Nick1}),
                   Pid
               end, ChannelNicks1),

          lists:foreach(fun(Channel) -> mnesia:delete_object(#channel_user{client = Nick, channel = Channel}) end, Channels),
          mnesia:delete({client, Nick}),
          Pids
    end,
    {atomic, Pids} = mnesia:transaction(F),
    ?USER_DATA = get_userdata(Nick),
    lists:foreach(fun(Pid) -> gen_server:cast(Pid, {send, ?HOST_MASK, "QUIT", [Message]}) end, Pids),
    if
        Reason =/= closed -> send(State, ?HOST_MASK, "QUIT", [Message]);
        true -> ok
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%

handle_data([$: | Data], State) ->
    [$  | Data2] = lists:dropwhile(fun(C) -> C =/= $ end, Data),
    handle_data2(Data2, State);
handle_data(Data, State) ->
    handle_data2(Data, State).

handle_data2(Data, State) ->
    [Command | Params] = parse_data(Data),
    %%io:format("~p >> ~p ~p~n",[State#state.socket, Command, Params]),
    Command1 = string:to_upper(Command),
    handle_command(Command1, Params, State).

parse_data(Data) ->
    parse_data(Data, [""]).

parse_data("", Result) ->
    lists:reverse([lists:reverse(Word) || Word <- Result]);

parse_data([$ , $: | Data], Result) ->
    lists:reverse([lists:reverse(Word) || Word <- Result]) ++ [Data];

parse_data([$  | Data], Result) ->
    parse_data(Data, ["" | Result]);

parse_data([C | Data], [Word | Result]) ->
    parse_data(Data, [[C | Word] | Result]).

handle_command("USER", Userdata, #state{nick = Nick} = State) ->
    [_Username, _Hostname, _Servername, _Realname] = Userdata,
    F = fun() ->
        mnesia:write_lock_table(client),
        mnesia:write(#client{nick = Nick, pid = self(), user = Userdata}),
        ok
    end,
    {atomic, R} = mnesia:transaction(F);

handle_command("QUIT", Args, _State) ->
    throw(quit);

handle_command("PING", Args, State) ->
    send(State, ?SERVER_NAME, "PONG", Args),
    State;

handle_command("NICK", [Nick], #state{nick = undefined} = State) ->
    F = fun() ->
        mnesia:write_lock_table(client),
        case mnesia:read({client, Nick}) of
            [] -> mnesia:write(#client{nick = Nick, pid = self()}), ok;
            _ -> exists
        end
    end,
    {atomic, R} = mnesia:transaction(F),
    case R of
    ok ->
        %%send(State, ?HOST_MASK, "NICK", [Nick]),
        send(State, ?SERVER_NAME, ?RPL_MOTDSTART, [Nick, "- MOTD: - "]),
        send(State, ?SERVER_NAME, ?RPL_MOTD, [Nick, "- WELCOME TO ZOMBOCOM"]),
        send(State, ?SERVER_NAME, ?RPL_ENDOFMOTD, [Nick, "End of MOTD"]),
        ?USER_DATA = get_userdata(Nick),
        send(State, ?HOST_MASK, "MODE", [Nick, "+i"]),
        State#state{nick = Nick};
    exists ->
        send(State, ?SERVER_NAME, ?ERR_NICKNAMEINUSE, ["*", Nick, "Nickname is already in use."]),
        State
    end;

handle_command("JOIN", [Channels], #state{nick = Nick} = State)
  when Nick =/= undefined ->
    Channels1 = string:tokens(Channels, ","),
    lists:foreach(fun(Channel) ->
              F = fun() ->
                      mnesia:write(#channel_user{channel = Channel, client = Nick}),
                      lists:flatten([mnesia:read({client, Nick1}) || #channel_user{client = Nick1} <- mnesia:read({channel_user, Channel})])
                  end,
              {atomic, Clients} = mnesia:transaction(F),
              ?USER_DATA = get_userdata(Nick), 
              send(State, ?HOST_MASK, "JOIN", [Channel]),
              send(State, ?SERVER_NAME, ?RPL_NOTOPIC, ["No topic"]),
            CModes = case mnesia:dirty_read(channel_modes, Channel) of
                [#channel_modes{modes = OldModes_}] -> OldModes_;
                [] ->
                    X = dict:store([$o|Nick], true, dict:new()),
                    mnesia:dirty_write(#channel_modes{channel = Channel, modes = X}),
                    X
            end,
              lists:foreach(fun(#client{nick = Nick1, pid = Pid}) ->
                        if
                            Pid =/= self() ->
                            gen_server:cast(Pid, {send, ?HOST_MASK, "JOIN", [Channel]});
                            true -> ok
                        end,
                        Nick2 = case dict:find([$o|Nick1], CModes) of
                            {ok, true} -> [$@|Nick1];
                            _ -> Nick1
                        end,                        
                        send(State, ?SERVER_NAME, ?RPL_NAMEREPLY, [Nick, "=", Channel, Nick2])
                    end, Clients),
              send(State, ?SERVER_NAME, ?RPL_ENDOFNAMES, [Nick, Channel, "End of names"])
          end, Channels1),
    State;

handle_command("WHO", [Channel], #state{nick = Nick} = State)
  when Nick =/= undefined ->
    F = fun() ->
        [Client || #channel_user{client = Client} <- mnesia:read({channel_user, Channel})]
    end,
    {atomic, Clients} = mnesia:transaction(F),
    lists:foreach(fun(Nick1) ->
              send(State, ?SERVER_NAME, ?RPL_WHOREPLY, [Nick, Channel, "user", "localhost", ?SERVER_NAME, Nick1, "+", "0 " ++ Nick1])
          end, Clients),
    send(State, ?SERVER_NAME, ?RPL_ENDOFWHO, [Nick, "End of who"]),
    State;

handle_command("MODE", [Channel, Modes | Params], #state{nick = Nick} = State) ->
    NewModes = parse_modes(Modes, Params),
    OldModes = case mnesia:dirty_read(channel_modes, Channel) of
        [#channel_modes{modes = OldModes_}] -> OldModes_;
        [] -> dict:new()
    end,
    NModes = dict:merge(fun(K,V1,V2) -> V2 end, OldModes, NewModes),
    mnesia:dirty_write(#channel_modes{channel = Channel, modes = NModes}),

    ?USER_DATA = get_userdata(Nick),
    Cmd = {send, ?HOST_MASK, "MODE", [Channel, Modes | Params]}, 
    Targets = case mnesia:dirty_read(channel_user, Channel) of
        [_ | _] = ChannelUsers -> lists:flatten([mnesia:dirty_read(client, Nick1) || #channel_user{client = Nick1} <- ChannelUsers]);
        [] -> send(State, ?SERVER_NAME, ?ERR_NOSUCHCHANNEL, [Channel, "No such channel"]), []
    end,
    lists:foreach(fun(#client{pid = Pid}) ->
        gen_server:cast(Pid, Cmd) end, Targets),
    State;

handle_command("PRIVMSG", [Target, Message], #state{nick = Nick} = State) ->
    Targets =
    case mnesia:dirty_read(channel_user, Target) of
        [_ | _] = ChannelUsers -> lists:flatten([mnesia:dirty_read(client, Nick1) || #channel_user{client = Nick1} <- ChannelUsers]);
        [] -> mnesia:dirty_read(client, Target)
    end,
    ?USER_DATA = get_userdata(Nick),
    Cmd = {send, ?HOST_MASK, "PRIVMSG", [Target, Message]},
    lists:foreach(fun(#client{pid = Pid}) ->
              if
                  Pid =/= self() -> gen_server:cast(Pid, Cmd);
                  true -> ignore
              end
          end, Targets),
    State;

handle_command(_Command, _Params, State) ->
    State.

parse_modes(Modes, Params) ->
    F = fun(M, {B,Ms,Ps}) ->
    Memb = lists:member(M, [$o, $l, $b, $v]),
    if
        M =:= $+ -> {true, Ms, Ps};
        M =:= $- -> {false, Ms, Ps};
        Memb ->
            [P|Pt] = Ps,
            {B, dict:store([M|P], B, Ms), Pt};
        true -> {B, dict:store([M], B, Ms), Ps}
        end
    end,
    {_, Parsed, _} = lists:foldl(F, {true, dict:new(), Params}, Modes),
    Parsed.

get_userdata(Nick) ->
    case mnesia:dirty_read(client, Nick) of
        [#client{user = Userdata}] ->
        if Userdata =/= undefined -> Userdata;
        true -> ["unknown", "unknown", "unknown", "unknown"]
        end;
        [] -> ["unknown", "unknown", "unknown", "unknown"]
    end.

send(State, Command, Params) when is_integer(Command) ->
    send(State, integer_to_list(Command), Params);

send(#state{socket = Socket}, Command, Params) ->
    [LastParam | Params1] = lists:reverse(Params),
    Params2 = lists:reverse(Params1),
    Line = Command ++
    lists:flatten([" " ++ S
               || S <- Params2]) ++ " :" ++
    LastParam ++ "\r\n",
    %%io:format("~p >> ~s", [Socket, Line]),
    ok = gen_tcp:send(Socket, Line).

send(State, From, Command, Params) when is_integer(Command) ->
    send(State, From, integer_to_list(Command), Params);

send(#state{socket = Socket}, From, Command, Params) ->
    [LastParam | Params1] = lists:reverse(Params),
    Params2 = lists:reverse(Params1),
    Line = ":" ++ From ++ " " ++
    Command ++
    lists:flatten([" " ++ S
               || S <- Params2]) ++ " :" ++
    LastParam ++ "\r\n",
    %%io:format("~p >> ~s", [Socket, Line]),
    ok = gen_tcp:send(Socket, Line).


