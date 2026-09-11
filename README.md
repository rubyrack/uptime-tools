# uptime-tools

Docker image, compose examples and Pterodactyl egg for the [Uptime](https://store.steampowered.com/app/4813880) dedicated server.

Image: `ghcr.io/rubyrack/uptime-server`. It contains SteamCMD and the launcher glue; the server itself is downloaded from Steam when the container starts, so a game update only needs a restart.

Player-facing docs: [wiki.playuptime.com/multiplayer/dedicated-server](https://wiki.playuptime.com/multiplayer/dedicated-server).

## Quick start

```sh
docker run -d --name uptime \
  --restart unless-stopped --stop-timeout 60 \
  -p 27016:27016/udp \
  -v uptime-data:/data \
  -e UPTIME_PASSWORD=change-me \
  ghcr.io/rubyrack/uptime-server
```

Leave `UPTIME_PASSWORD` out for an open server. `docker logs -f uptime` shows the download, then `[steam] game-server link up`, then a few seconds later:

```text
[server] game-server SteamID: 90292215011180567 (players reach this world over Steam's relay by this id)
```

Players paste that number into Join > Dedicated servers > Add. No port is needed for it. The ID changes on every start.

For an entry that survives restarts, forward UDP 27016 and have players add `your.public.ip:27016` instead. Use the IPv4 address, not a hostname.

`docker stop uptime` saves the world before exiting.

## Variables

| Variable | Default | |
|---|---|---|
| `UPTIME_PASSWORD` | none | Join password, 5 to 128 characters. `UPTIME_PASSWORD_FILE` reads it from a file. Unset means an open server: anyone with the address or the SteamID can join, and the log says so at start. |
| `UPTIME_NAME` | `Uptime server` | |
| `UPTIME_WORLD` | `worlds/main.save` | Under `/data`. Created from the scenario on first start. |
| `UPTIME_SCENARIO` | `garage-to-glory` | Used only when the world is created. `garage-to-glory`, `arm-race`, `sandbox`. |
| `UPTIME_SITE` | `garage` | Sandbox only: the site the world starts at. `garage`, `basement`, `small_colo`, `small_campus`. Only for a new world. |
| `UPTIME_MAX_PLAYERS` | `4` | `0` for no cap. |
| `UPTIME_AUTOSAVE_SECS` | `300` | `0` saves only on stop. |
| `UPTIME_HARD` | `0` | `1` builds a new world in hard mode. Existing worlds keep their mode. |
| `UPTIME_PUBLIC` | `0` | `1` lists the server in the game's Internet tab. Needs the query port reachable directly. |
| `UPTIME_SEED` | random | Only for a new world. |
| `UPTIME_QUERY_PORT` | `27016` | UDP. The port to publish. |
| `UPTIME_STEAM_PORT` | `27015` | UDP, internal. Must differ from the query port. |
| `UPTIME_PUBLIC_ADDR` | | `host:port` players should record when it differs from what the server sees (port forward, tunnel). Hostnames are resolved to IPv4 at start. |
| `UPTIME_TUNNEL` | `none` | `playit` or `pinggy`. |
| `PUID`, `PGID` | `1000`, `1000` | The user and group the server runs as. Files under `/data` are owned by them; set these to match a bind mount's owner. Ignored when the container is started with `--user`. |
| `UPTIME_SERVER_DIR` | `/data/server` | A server you staged yourself instead of one SteamCMD downloads. Bind-mount it; read-only is fine, nothing is written to it. Setting this defaults `UPTIME_UPDATE` to `0`. Required on arm64 hosts, see [Local server build](#local-server-build). |
| `UPTIME_UPDATE` | `1` | Update from Steam on every start. `0` runs the installed build. |
| `UPTIME_UPDATE_CHECK_MINS` | `30` | While running, check Steam for a new server build this often. When one exists and no players are connected, the server saves, exits and restarts on the new build. `0` disables the check; it is also off when `UPTIME_HTTP_PORT` is `0`. |
| `UPTIME_VALIDATE` | `0` | `1` validates all server files on start. |
| `UPTIME_HTTP_PORT` | `9875` | Read-only API on loopback, used by the healthcheck. `0` disables it. |

Arguments after the image name are passed to the server and override the environment: `... uptime-server --max-players 8`.

## Ports and tunnels

Game traffic goes over Steam's relay; no inbound port is needed for that. The query port (UDP 27016) is what Favourites, History and the Internet tab ping. Without it the server still runs and is joinable by SteamID, but shows as unreachable in those lists.

- Public address: `-p 27016:27016/udp`.
- Home router: forward UDP 27016. If the outside port differs, set `UPTIME_PUBLIC_ADDR=your.public.ip:PORT`.
- No way to open a port: `UPTIME_TUNNEL=playit` or `pinggy`. Favourites and History work through the tunnel; the Internet tab does not.

### playit

1. Create an agent at [playit.gg](https://playit.gg) and copy its secret key.
2. Add a UDP tunnel to `127.0.0.1:27016` in the dashboard. playit shows an address like `something.gl.at.ply.gg:12345`.
3. Set `UPTIME_TUNNEL=playit`, `PLAYIT_SECRET_KEY`, `UPTIME_PUBLIC_ADDR` to that address, and publish no ports. See `examples/playit.yml`.

### Pinggy

Set `UPTIME_TUNNEL=pinggy` and publish no ports. The container opens the tunnel, reads the address Pinggy assigns and passes it to the server. Without a token the address changes on every start; `docker logs uptime 2>&1 | grep 'pinggy public address'` prints the current one. `PINGGY_TOKEN` takes a Pro token for a reserved port. See `examples/pinggy.yml`.

Other UDP tunnels: add a script under `docker/tunnels/` that starts the agent and prints `host:port`.

## Data

`/data/server` is the Steam install. `/data/worlds` holds the world file, its `.1` and `.2` backups, and `adminlist.txt`, `bannedlist.txt`, `permittedlist.txt` (one SteamID64 per line). Everything is owned by `PUID:PGID`; for a bind mount, set those to the directory's owner.

Backup:

```sh
docker run --rm -v uptime-data:/data -v "$PWD":/backup alpine tar czf /backup/uptime-worlds.tgz -C /data worlds
```

Stop the container first for a consistent copy, or take the `.1` file, which is the previous completed save.

## Updates

A game update changes the version players must match. With the defaults the container updates the server on every start and, every 30 minutes, asks Steam whether a new build exists. When one does and nobody is connected, the server saves and exits, and the container's restart policy brings it back on the new build. While players are on, it waits and checks again. Set `UPTIME_UPDATE_CHECK_MINS=0` to restart on your own schedule instead.

The image itself changes rarely (SteamCMD, base image, tunnel agents); `docker compose pull` now and then is enough.

## Local server build

`UPTIME_SERVER_DIR` points the container at a server you supply, and turns the Steam update off. Two uses: running a build that is not on Steam, and running the image on an **arm64 host**, where the download cannot happen in-container.

The reason is one binary. Steam's Linux SteamCMD is 32-bit x86, and no emulator on arm64 runs it: it segfaults in `Loading Steam API` under Rosetta, under qemu, and as a `linux/386` container. `--platform linux/amd64` does not help, because the platform flag is not the problem. Everything else here is 64-bit and runs fine under emulation, including the server and `steamclient.so`, so staging the depot outside is enough. Apple Silicon, Graviton, Ampere and Asahi are all this case.

Stage it with a SteamCMD that works. On macOS that is the native build, which is 64-bit and needs no emulation:

```sh
mkdir steamcmd && cd steamcmd
curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz | tar -xz
./steamcmd.sh +@sSteamCmdForcePlatformType linux +@sSteamCmdForcePlatformBitness 64 \
  +force_install_dir "$PWD/../server" +login anonymous \
  +app_update 1007 validate +app_update 5053430 validate +quit
```

App 1007 is Valve's redist and is not optional: it carries `linux64/steamclient.so`, which the game depot may not redistribute and without which the Steam link never comes up. The container says so at start if it is missing.

Then mount it:

```sh
docker run -d --platform linux/amd64 --name uptime \
  --restart unless-stopped --stop-timeout 60 \
  -p 27016:27016/udp \
  -v uptime-data:/data \
  -v "$PWD/server":/server:ro \
  -e UPTIME_SERVER_DIR=/server \
  -e UPTIME_PASSWORD=change-me \
  ghcr.io/rubyrack/uptime-server
```

`/data` still holds the worlds and the access lists; only the install moves. Because the Steam update is off, the 30-minute new-build check is off too, so re-run the staging step yourself when the game updates.

## Pterodactyl

`pterodactyl/egg-uptime.json`, PTDL_v2, Linux x86_64. It runs on the community SteamCMD image `ghcr.io/parkervcp/steamcmd:debian`, not on the image above: Wings owns the server directory and the uid it runs as, and this image is built for `docker run`. One allocation: the query port. The egg's installer downloads the server into the server volume; on every start the SteamCMD image updates app 5053430 when `AUTO_UPDATE` is 1, then runs the startup line, which is the depot's `start_server.sh`. Stop sends SIGINT and the server saves before exiting.

## Building

```sh
docker buildx build --platform linux/amd64 -t uptime-server docker
```

`.github/workflows/image.yml` publishes to GHCR on push and weekly. `smoke.yml` boots the image against Steam on an amd64 runner, waits for the SteamID line, checks health, stops, and restarts into the saved world.

## Status

Boot, healthcheck, stop-save and reload are tested with a pre-installed depot. The SteamCMD download at start needs an x86 host and is covered by the smoke workflow; on arm64 it cannot work, and [Local server build](#local-server-build) is the supported route there. That route was run end to end on Apple Silicon: Steam link up, healthy, stop-save, restart into the saved world. The playit and pinggy modes have not been run end to end; the Pinggy address parsing follows its documentation.
