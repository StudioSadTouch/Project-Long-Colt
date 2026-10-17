# Hosting and joining servers

Long Colt runs online games in three ways (protocol 12):

| Way | Who hosts | Reachable from |
|---|---|---|
| **Listen server** | a player, from **Multiplayer → Host**, who also plays | your LAN; the internet with UPnP on, or the port forwarded by hand |
| **Dedicated server** | the game launched headless with `--server`, on a PC, the homelab or a VPS; nobody plays on it | wherever its UDP port is reachable |
| **Join** | anyone, by address | |

Everything is UDP on one port, 7777 by default. LAN discovery (the "On your network" list)
uses UDP 7778 broadcasts on the local network only.

## Joining

**Multiplayer → Join**:

- **Address**: an IP or a domain name, with `:port` if it isn't 7777. For example:
  - `203.0.113.7`
  - `longcolt.example.com:7800`
  - `[2001:db8::7]:7777` for IPv6
- **Password**: only if the server has one. A wrong or missing password is refused with the
  reason.
- **Favorite** stars the address in the box.
- **Favorites and recent**: starred servers first, then the last 8 servers you joined. Click one
  to fill the box; double-click to join.
- **On your network**: games found on the LAN. Joining one also fills the address box, so you can
  add a password and press Join if it asks for one.

On a dedicated server the lobby shows the server's name, and the match starts by itself.

## Listen server (host from the menu)

**Multiplayer → Host**: map, player count, bots and rules as before, plus:

- **Port**: the UDP port players connect to (default 7777; saved).
- **Open to internet (UPnP)**: asks your router to forward the port. The lobby shows the result:
  - success: "Open to the internet at 203.0.113.7:7777". Give friends that address.
  - failure: "No UPnP router found ... forward UDP 7777 on your router by hand".
  - Some routers have UPnP turned off. It can't work behind carrier-grade NAT (some mobile and
    fibre ISPs), where only a dedicated server on a reachable machine or a VPS works.
- **Password** (optional): joiners must type it.

The mapping is removed when you leave the lobby or the match.

## Dedicated server

The normal Linux (or Windows) build runs headless as a server:

```
"Project Long Colt.x86_64" --headless -- --server --server-config /path/to/server.cfg
```

- The server is not a player. It isn't in the player list, and no body spawns for it.
- **Starting:** when the first player joins, the first match starts after `start_delay` seconds.
  Later joiners drop straight into the running match.
- **Rotation:** a match ends at the mode's own win (score limit, captures, Horde game over) or
  at its time limit. After `next_delay` seconds of the game-over screen, the next match in the
  rotation loads for everyone. The rotation loops.
- **Empty server:** when the last player leaves, the server stops the match and idles until
  someone joins.
- **Logging:** joins, leaves, match starts, time limits and game overs go to stdout with a
  `[Server hh:mm:ss]` prefix.
- **No config file:** with no `--server-config`, it uses `user://server.cfg`. Wherever the path
  points, a missing file gets the example written there first.

### Config (`tools/server/server.cfg.example`)

```ini
[server]
name="Long Colt Server"   ; shown in the lobby and the LAN list
port=7777                 ; UDP
password=""               ; "" = open
upnp=false                ; ask the router to forward the port
lan_beacon=true           ; also list it under "On your network"
start_delay=10.0          ; seconds from the first join to the first match
next_delay=15.0           ; seconds of game over before the next match

[bots]
fill=true                 ; fill empty slots with bots (and refill when players leave)
count=3
difficulty="Normal"       ; Easy, Normal, Heroic, Legendary

[match_1]                 ; one section per match, played in name order, then looping
map="lockout"             ; lockout, headlong, ivory_tower, zanzibar, kamino, range
mode="ffa"                ; ffa, team_4v4, team_slayer
rules="slayer"            ; slayer, swat, ctf, horde, range
time_limit_minutes=15.0   ; 0 = until the mode's own win
```

Bad values never stop the server. Each one is logged as `config: ...` at startup and replaced
with a default:

- an unknown map, mode, rules or difficulty;
- a port out of range;
- CTF in Free for All (moves to Team 4v4);
- Horde in a team mode (moves to Free for All: Horde is co-op).

When a time limit ends a match, the leader wins:

- CTF: the team with more captures;
- team modes: the team with more kills;
- Horde: "The defenders";
- otherwise: the top fragger.

### Docker (homelab)

From the project root, after exporting the Linux build to `build/linux/`:

```
docker compose -f tools/server/docker-compose.yml up -d --build
docker logs -f longcolt-server
```

- The image is `debian:bookworm-slim` plus the exported binary. The binary only needs glibc. It
  runs as a non-root user.
- The config lives in the `longcolt-config` volume at `/config/server.cfg`. The first start
  writes the example there. Edit it, then
  `docker compose -f tools/server/docker-compose.yml restart`.
- The compose file publishes `7777:7777/udp`. If you change `port` in the config, change the
  mapping too.
- UPnP from inside a container only works with `network_mode: host`. On a homelab, forwarding
  the port on the router by hand is simpler.
- `.dockerignore` keeps the build context to the one binary.

### Reaching it from the internet

1. Forward **UDP** `<port>` on the router to the server machine, or set `upnp=true`.
2. Give players the router's public IP, or a domain pointing at it (dynamic DNS works), plus the
   port if it isn't 7777.
3. Check the server's firewall allows UDP `<port>` in (for example `ufw allow 7777/udp`).

ENet speaks plain UDP: a reverse proxy for web traffic (such as Nginx Proxy Manager's HTTP
hosts) can't front it.

## Testing

- `tests/server_hosting_self_test.gd` covers:
  - address parsing;
  - config parsing, including the shipped example and bad values;
  - the recent and favorite lists;
  - the Multiplayer menu.
- `tests/dedicated_server_check.gd` runs a real dedicated server and a client against it:
  - missing and wrong passwords are refused, and the right one is accepted;
  - the client joins by host name;
  - the server isn't a player;
  - the match starts itself with a bot;
  - the time limit ends it, and the rotation loads the next map.

  Start the server (command in the file header), then the check. The same check passed against
  the server running in Docker.
- UPnP isn't exercised by tests: it would open a real port on the router of whoever runs them.
