{application, tircd,
 [{description, "tedium irc daemon"},
  {id,           "tircd"},
  {vsn,          "v1.0"},
  {modules,      [client, tircd, server, server_sup, client_sup]},
  {registered,   [server]},
  {applications, []},
  {mod,          {tircd, []}}
]}.


