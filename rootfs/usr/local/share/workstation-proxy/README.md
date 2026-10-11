# Proxy: publish web apps on subdomains

This folder configures the workstation's optional Caddy proxy. One file per project gives
it a subdomain, so nobody has to open or remember extra ports. Using it is optional:
servers on their own ports keep working.

Examples below use `example.com` for the public domain (`PROXY_DOMAIN`) and `home.lan`
for the LAN domain (`PROXY_LAN_DOMAIN`). Your deployment sets the real values. Run
`workstation-proxy status` to see them.

## Publish a running server

Bind your server to `127.0.0.1` on any free port, then create `sites/<name>.caddy`:

```caddy
import proxy myapp 127.0.0.1:5173
```

Then run `workstation-proxy reload`. The app is now at:

- `https://myapp.example.com` (trusted certificate)
- `http://myapp.home.lan`
- `https://myapp.home.lan` (the internal CA; install its root from the sites page)

The file name is the name shown on the index page. Names use `a-z`, `0-9` and `-`.

## Services on other machines: `<service>.<host>`

Name the file `sites/<service>.<host>.caddy`, e.g. `sites/dockge.nas.caddy`:

```caddy
import proxy dockge.nas 192.0.2.20:5001
```

This gives `https://dockge.nas.example.com`. All services on one host share one wildcard
certificate (`*.nas.example.com`), so only the first service on a new host waits a
few minutes for it (`reload` says so). If the host has its own DNS record
(`nas.example.com` → its IP), it also needs a `*.nas.example.com` record pointing
at the proxy. With `PROXY_MANAGE_DNS=true` the proxy creates that record itself.

## Publish static files without running a server

Put the files in `www/<name>/`, or symlink a build output folder there:

```sh
ln -s /workspace/myproject/dist www/myproject
workstation-proxy reload
```

`index.html` is the start page. Dotfiles are never served. A symlink must point inside
`/workspace`, at a folder with no `.git` or `.env*` and no links leading out of it.
Anything else is skipped, and `reload` shows the reason. A site file with the same name
takes precedence over a `www/` folder. `www/` is not tracked by git.

## Anything Caddy can do

`import site <name> { ... }` gives `<name>` all of the addresses above, with any Caddy
directives inside:

```caddy
import site api {
	handle_path /v1/* {
		reverse_proxy 127.0.0.1:8080
	}
	handle {
		root * /workspace/api/public
		file_server
	}
}
```

A file can also contain plain Caddy site blocks for other names. Names under the
public domain reuse its wildcard certificate.

## Forward a raw TCP port (SSH, databases, ...)

Create `tcp/<name>.caddy`:

```caddy
import forward 22 192.0.2.20:2222
```

Then run `workstation-proxy reload`. Port 22 on the proxy's addresses now
forwards to `192.0.2.20:2222`. TCP has no hostname, so each port goes to exactly
one destination, and every `*.example.com` name reaches it (for example
`ssh git@code.example.com`). Any [caddy-l4](https://github.com/mholt/caddy-l4)
route is allowed in these files.

## Commands

| Command | What it does |
|---|---|
| `workstation-proxy check` | Validate without applying; lists skipped entries |
| `workstation-proxy show` | Print the generated Caddy configuration (no secrets) |
| `workstation-proxy reload` | Rebuild and apply. **Run it after every edit.** If the configuration is invalid, the running one stays |
| `workstation-proxy sites` | List published sites, their URLs and skipped entries |
| `workstation-proxy status` | Running or failing, plus the last error |
| `workstation-proxy logs [-n N]` | Recent Caddy log lines |
| `workstation-proxy ca` | Where to get the internal CA root certificate |

## Reserved and automatic

- `paseo` is the Paseo web UI; `sites` is the index page and the CA root download.
- Unknown names show a 404 page listing the published sites.
- Files here are trusted configuration. Never put secrets in them; tokens come from the
  container environment.
