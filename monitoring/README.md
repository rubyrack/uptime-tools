# Uptime metrics and dashboards

Prometheus and Grafana, already wired to the read-only `/metrics` endpoint that every Uptime world serves. One command brings it up. There is no login and no panels to build. It opens on a control room showing cash, capacity headroom, traffic and open incidents.

It works against a game running on your own machine and against a dedicated server container. It only reads. Nothing about the game or the server image changes.

## Quick start

A game on this machine:

```sh
./stack.sh up
```

Then open **http://127.0.0.1:3000**. Start a game if one is not already running. The scrape connects within a few seconds and you do not need to restart anything here.

The dedicated server in this repository:

```sh
./stack.sh up server
```

Same URL. This layer starts the server container too, because it is an overlay onto the repository's own compose file. If the server is already running, compose leaves it alone and adds the other three containers.

Stop either with `./stack.sh down`, which keeps the recorded history, or `./stack.sh down --wipe`, which deletes it.

You do not need `stack.sh`. It picks the compose file that matches your machine and reports whether the scrape landed. It also prints the command it ran, so you can run that command directly once you know which one you want:

```sh
docker compose up -d                                               # this machine, Docker Desktop or OrbStack
docker compose -f compose.linux.yml up -d                          # this machine, native Linux daemon
docker compose -f docker-compose.yml -f monitoring/compose.server.yml up -d   # server, from the repo root
```

## The dashboards

There are five, split the way the game splits its own wallboards and console pages. Internet is the WAN edge and Network is the fabric inside the building. They are separate on purpose.

| Dashboard | |
|---|---|
| **Control room** | The whole provider on one screen. Cash, reputation, customers served, hosts online, open incidents and work orders. Bar gauges for how much of the uplink, cooling, memory, disk and the public IP block is in use. Below that, revenue against operating cost, uplink traffic with attack volume on the same axis, and drops at all three stages. A collapsed row holds the numbers that say whether the figures are still moving. |
| **Internet** | The WAN edge. Egress against the ceiling the simulation actually enforces, the nameplate the circuits are billed at, and the gap between them. A panel names which of the three terms is binding, and another shows all three side by side so you can see the shortest one. Facility egress drops and the public IP pool. |
| **Network** | The fabric inside the building. Total host NIC traffic, and the north-south against east-west split stacked so the total height is the fabric total. Inter-zone trunk state as a timeline, per-lane load, a table of which lane is shedding most, and the cable fleet against its failures. |
| **Capacity** | The fleet and the room it sits in. Hosts racked against hosts online, where the gap is hardware you are paying for and not earning from. Warm and contended counts, the busiest host's load, memory and disk weighted by nameplate, and heat against installed cooling. |
| **Business and growth** | Cash with a marked zero line. Recurring, one-time and operating cost, and revenue booked per simulated hour. Customers served against customers billed, reputation, and the estate stacked by entity kind. |

Every panel shades the periods when an incident was open, an attack was inbound, a trunk was down or hosts were contended, so a drop in revenue lines up with its cause.

Two labels are worth knowing before you read them. **Operating cost excludes hardware**: a purchase converts cash into an asset and reaches the accounts as depreciation, so revenue minus operating cost is not profit. And **the nameplate is not the ceiling**: two 100 G circuits behind two routers that cannot share a prefix bill 200 and deliver whatever the larger router forwards, which is why utilisation divides by the effective figure everywhere.

The metric list lives in the game, not here. The game serves its own catalog at `http://127.0.0.1:9875/api/v1/metrics/catalog`, with the name, kind, unit and help text for every family, and Swagger at `/docs`.

## The scrape interval is 5s, and that matters

The game publishes the read model behind `/metrics` on a 1 Hz cadence, behind a demand gate. It stops publishing about a minute after the last read, and a reader that arrives after the gate has closed takes one stale sample before it reopens. Anything polling faster than once a minute keeps the mirror warm, so every sample is fresh. **Do not raise the interval past 60s.**

Scraping costs the simulation nothing else. The game publishes on its cadence rather than per request, so a second scraper adds no work.

## Reaching a loopback endpoint

The game's API listens on `127.0.0.1` only, deliberately, and no flag widens it. It serves read-only data about your own world and it has no authentication. Everything here works around that instead of changing it. This is the only part of the setup that is not obvious.

| Case | How the container reaches it |
|---|---|
| Game on this machine, Docker Desktop or OrbStack | Docker proxies `host.docker.internal` to the host, and it reaches the host's loopback. This is `docker-compose.yml`. |
| Game on this machine, native Linux daemon | A bridge gateway cannot reach a loopback listener. The containers join the host's network stack instead, which makes `127.0.0.1:9875` the game's API. This is `compose.linux.yml`. |
| Dedicated server container | A socat sidecar shares the server container's network namespace, which puts it inside that container's loopback, and it re-listens on `0.0.0.0:9876`. The namespace belongs to the server, so Prometheus reaches it as `uptime:9876`. No extra published port, and no change to the server image. This is `compose.server.yml`. |

`stack.sh` picks between them by asking the daemon what it is. Force the choice with `UPTIME_MONITORING_LAYER=desktop`, `hostnet` or `server` if it guesses wrong.

## Watching more than one world

Targets come from file discovery rather than a static list. The compose layer mounts one of `prometheus/targets/*` at `/etc/prometheus/targets`, and Prometheus re-reads that directory when it changes. To add a second server, drop another file in beside the first:

```json
[
  { "targets": ["10.0.0.14:9876"], "labels": { "world": "eu-west box" } }
]
```

You do not need to restart or reload Prometheus. It attaches the `world` label to every series from that target, so you can filter the dashboards by it.

## Ports and access

Grafana is published on `127.0.0.1:3000` and Prometheus on `127.0.0.1:9090`, which matches how the endpoint they read is published. There is no login screen, and every visitor is an admin of the single org. That is fine for a dashboard on loopback showing your own save file. It is not fine on a network you do not control.

To reach a server's dashboards, forward the port over SSH rather than opening it:

```sh
ssh -L 3000:127.0.0.1:3000 you@your.server
```

If you do open it, drop the `127.0.0.1:` prefix from the `ports:` line and set `GF_AUTH_ANONYMOUS_ENABLED=false` in the same file. The Linux layer has no published ports to change, because host networking puts Grafana on the machine's own `0.0.0.0:3000`. Block it with a firewall rule there.

## What is where

| | |
|---|---|
| `prometheus/prometheus.yml` | Scrape config. One job, file discovery. |
| `prometheus/targets/{desktop,hostnet,server}/` | One target file each. The compose layer picks which one it mounts. |
| `grafana/provisioning/` | Datasource and dashboard providers. Grafana reads these at start. |
| `grafana/dashboards/*.json` | The dashboards. If you edit one in the browser, Save writes to Grafana's own database and your change survives a restart. Grafana reloads a file only when that file changes. |
| `testdata/metrics.txt` | A captured exposition body that matches the exporter family for family. CI uses it, and you can take screenshots from it without playing to a mid-campaign save. |

## When it is not working

| | |
|---|---|
| Grafana opens and every panel says No data | The scrape is not landing. `http://127.0.0.1:9090/targets` gives the reason in one line. |
| The target is down and the game is running | The layer does not match this machine. Try `UPTIME_MONITORING_LAYER=hostnet ./stack.sh up`. Check that `curl http://127.0.0.1:9875/health` answers on the host at all. |
| The target is down and the server is running | The server has to be past its first world publish. Run `docker logs uptime \| tail -20`. If you set `UPTIME_HTTP_PORT` to something other than 9875, put the same value in a `.env` file beside the repository's `docker-compose.yml` so the relay follows it. |
| The numbers are frozen but the scrape is up | Open the Simulation health row on the control room. Publishes per second at zero means the engine is not reaching its publish point. Apply queue depth tells you whether it is behind instead. |
| Everything is stale by about one scrape interval | Someone raised the scrape interval past the game's demand gate. Put it back under 60s. |
