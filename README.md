# Minecraft Server

A ready-to-run **PaperMC 26.3** server with a one-command public tunnel, the
[MobHead](https://github.com/mdmuntakim/mobhead) plugin, Docker support and a protocol-level test suite.

Players can join from anywhere without opening a router port: the tunnel
script exposes the local Minecraft port through [bore.pub](https://bore.pub),
which needs no account.

## Quick start

Requirements: **Java 25+**, `curl`, `python3` and `bash`.

```bash
./scripts/start.sh          # downloads Paper 26.3, starts the server
```

In a second terminal:

```bash
./scripts/tunnel.sh
# ==> tunneling 127.0.0.1:25565 to bore.pub (bore 0.5.3)
# ... listening at bore.pub:41234
```

Players connect to the printed `bore.pub:41234` address. The port is random per
run; keep the tunnel process alive while the server runs. For a stable, named
address use a [playit.gg](https://playit.gg) agent or host your own
[bore server](https://github.com/ekzhang/bore) and call
`./scripts/tunnel.sh --to your.tunnel.host`.

The first start creates the world, downloads the Paper jar (55 MB) and verifies
its SHA-256. `server/eula.txt` is set to `eula=true`; starting the server means
accepting the [Minecraft EULA](https://aka.ms/MinecraftEULA).

## Run a public server from GitHub Actions

The `server` workflow has a **Run workflow** button: open the **Actions** tab,
pick **server** on the left, then **Run workflow**. One run boots Paper,
installs the newest MobHead release from
[mdmuntakim/mobhead](https://github.com/mdmuntakim/mobhead) and opens a
bore.pub tunnel, so players can join from anywhere while the run is alive.

| Input | Default | Meaning |
| --- | --- | --- |
| `duration_minutes` | `300` | minutes online, 1-330 |
| `public_port` | empty | fixed bore.pub port (e.g. `25999`), empty = random |
| `memory` | `2G` | Java heap |
| `paper_version` | `26.3` | Paper version |
| `mobhead` | `true` | install the latest MobHead release |
| `online_mode` | `true` | require a Minecraft account |
| `save_world` | `true` | upload the world as an artifact when the run ends |

The address appears in the run summary and in the log as soon as the tunnel
is up:

```
Minecraft is public:  bore.pub:25999
```

Enter that with **Direct Connection** in Minecraft. Cancel the run to stop the
server; the logs and (optionally) the world are kept as run artifacts for
seven days. The MobHead version, tag and SHA-256 are printed during the run,
so the jar is always the latest published release and never a stale copy in
this repository.

A GitHub-hosted runner has no inbound public IP, so the game address is a
tunnel endpoint rather than the runner's own address. With `public_port` set
the endpoint stays the same between runs as long as that bore.pub port is
free; otherwise the run falls back to a random port and says so. For a
permanent named address, pass `--to` to a self-hosted
[bore](https://github.com/ekzhang/bore) server or use a
[playit.gg](https://playit.gg) agent.

The same run is available locally:

```bash
DURATION_MINUTES=120 PUBLIC_PORT=25999 ./scripts/run-server.sh
```

## Test it

```bash
./scripts/test-server.sh
```

The test downloads Paper, boots it on a free port, and then checks:

1. the server reaches `Done (…)` without crashing;
2. a real **Minecraft Server List Ping** returns the version, player count and
   MOTD (`scripts/ping.py`);
3. **MobHead** is installed, `/mobhead selftest` returns `PASS` and
   `/mobhead info iron_golem` answers over RCON (`scripts/rcon.py`);
4. the server answers the same status ping through the **public tunnel**
   (`bore.pub:<random>`).

Useful switches:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SKIP_TUNNEL=1` | `0` | Run only the local checks |
| `WITH_MOBHEAD=0` | `1` | Test plain Paper without the plugin |
| `KEEP_WORK=1` | `0` | Keep the test world and `console.log` |
| `PAPER_VERSION` | `26.3` | Paper version to download |
| `SERVER_PORT` | `25565` | Preferred local port |

### Test matrix

Last run on Linux x86_64, Temurin 25.0.5, Paper 26.3 build 256, MobHead 26.3 r3:

| Check | Result |
| --- | --- |
| Paper boot | PASS |
| Status protocol (`ping.py`) | PASS |
| MobHead `/mobhead selftest` (RCON) | PASS |
| Public tunnel ping (`bore.pub`) | PASS |

## Configuration

`server/server.properties` is a normal Paper configuration file. The launcher
reads these environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SERVER_DIR` | `server/` | World, jar and configuration directory |
| `MEMORY` | `2G` | Java heap (`-Xms` and `-Xmx`) |
| `PAPER_VERSION` | `26.3` | Paper version |
| `PAPER_BUILD` | `latest` | `latest` or a build number |
| `SERVER_PORT` | `25565` | Local port for the tunnel |
| `JAVA_BIN` | `java` | Java 25 binary |
| `BORE_SERVER` | `bore.pub` | Tunnel server |
| `MOBHEAD_JAR_URL` | latest release asset | Plugin jar to install |

The server is public by default (`online-mode=true`, no whitelist). For a
long-lived world, enable the whitelist and consider disabling RCON:

```properties
white-list=true
enforce-whitelist=true
```

## Docker

```bash
docker compose up --build -d
docker compose logs -f
```

The container exposes `25565`, downloads the pinned Paper build on first start
and stores the world in the mounted `server/` directory. Run the tunnel on the
host (`./scripts/tunnel.sh`) or inside the container network if you prefer.

To package the scripts and default configuration without a runtime:

```bash
./scripts/build-dist.sh
# dist/minecraft-server-26.3.tar.gz
```

## Layout

```
scripts/get-paper.sh       resolve the latest Paper build, verify SHA-256
scripts/start.sh           start the server, download on first run
scripts/run-server.sh      timed public run used by the server workflow
scripts/tunnel.sh          public bore tunnel (pinned, checksum verified)
scripts/install-mobhead.sh install the published MobHead jar
scripts/ping.py            Minecraft status protocol client
scripts/rcon.py            Source RCON client
scripts/test-server.sh     end-to-end test
scripts/build-dist.sh      build the release bundle
server/                    server.properties and eula.txt
docker/                    Dockerfile
```

Runtime output (`paper.jar`, the world, logs, caches) is git-ignored and never
committed.

## Security notes

* `bore.pub` publishes the port publicly; anyone with the address can reach the
  server list. Keep `online-mode=true` and use a whitelist for a private world.
* RCON is disabled in `server.properties`; the test enables it on a random port
  with a random password inside the temporary test directory only.
* The Paper jar and the bore binary are pinned and verified before use.
