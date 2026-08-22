# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Home Assistant add-on repository (`repository.yaml` at the root makes it one)
holding two add-ons, `nginx_ui/` and `fedora_podman/`. There is no application
code, no test suite and no build system: the deliverables are add-on manifests,
Dockerfiles and shell scripts that Home Assistant's Supervisor builds and runs
on the user's own machine.

## Working on it

There is nothing to compile and nothing to run locally — the add-ons only exist
as add-ons once the Supervisor builds them. What can be checked here:

```bash
shellcheck <script>                       # every shell script must pass clean
bash -n <script>                          # sh -n for the /command/with-contenv sh ones
python3 -c "import yaml; yaml.safe_load(open('nginx_ui/config.yaml'))"
python3 tools/make-logos.py               # regenerates icon.png/logo.png for both add-ons
```

Scripts that read `/data/options.json` and write to absolute container paths
take those paths from `: "${VAR:=/default}"` defaults, so they can be exercised
outside a container by overriding the variables. Add the override rather than
hard-coding a path when a script gains a new one, and dry-run the change with a
hand-written `options.json` — that is the only test loop this repository has.

Docker is not available in every environment used to work on this, so a real
image build may not be possible; say so rather than implying an untested change
was verified.

## Add-on manifests

`config.yaml` is the contract with the Supervisor, and mistakes there fail at
install time on a user's machine, not here. Points that have caught this repo
before:

- `version` is what makes Home Assistant offer an update. A new base image tag
  without a version bump never reaches an installed add-on, which is why
  `.github/workflows/bump-images.yml` moves both together.
- `init: false` where the image's own entrypoint is a process supervisor
  (s6-overlay in `nginx_ui`); `init: true` where a single foreground process
  needs Docker's tini to reap orphans (`fedora_podman`).
- Only `/data` (and mapped paths like `app_config`) survive an update. Anything
  written elsewhere in the container is thrown away on the next rebuild.
- `map:` uses the object form (`- type: ssl` / `read_only: false`); the
  `- ssl:ro` string form is legacy.
- With `host_network: true` the Supervisor publishes nothing, but `ports:` is
  still what `webui:`'s `[PORT:n]` resolves against, and `[PROTO:option]` reads
  a boolean option by name.

## The two add-ons

**`nginx_ui/`** wraps upstream's `uozi/nginx-ui` image, which is supervised by
s6-overlay. The add-on adds two services under
`rootfs/etc/s6-overlay/s6-rc.d/` rather than an entrypoint of its own:
`init-addon` (a oneshot that everything else depends on) and `keepalived` (a
longrun that idles unless `ha.enabled`). `init-addon` symlinks `/etc/nginx` and
`/etc/nginx-ui` into `/data`, and translates add-on options into
`NGINX_UI_<SECTION>_<KEY>` files under `/run/s6/container_environment`, which
upstream reads as environment variables that override its `app.ini`. Env-var
names are the Go field names in SCREAMING_SNAKE (`SSLCert` → `SSL_CERT`).
Everything else is configured from the panel, deliberately: the add-on does not
re-declare nginx in an options schema.

**`fedora_podman/`** is a Fedora userland with Podman reached over SSH, built
from `build.yaml`'s `BUILD_FROM`. One entrypoint script sets things up and
`exec`s sshd; the pieces it sources live in `rootfs/usr/local/bin/`. It is as
privileged as an add-on gets and its documentation says so repeatedly — keep it
that way.

The division between them is the repository's organising idea, explained in the
root README: an add-on exists for what genuinely needs the Supervisor (boot
order, mapped paths, persistent storage); anything that would be a thin wrapper
around someone else's image is meant to run as a container inside
`fedora_podman` instead.

## Conventions

- Comments and documentation explain *why*, including what was tried and
  rejected. Matching that density matters more here than brevity — the existing
  files are the style guide.
- Each add-on carries three documents with different audiences: `README.md` for
  someone reading the repository, `DOCS.md` for the Documentation tab in Home
  Assistant, and `CHANGELOG.md`. A user-visible change touches all three, and
  the option reference in `DOCS.md` must match `config.yaml`'s schema exactly.
- Icons and logos are drawn by `tools/make-logos.py`, never hand-edited, so the
  two add-ons keep one palette and geometry. Regenerate rather than editing a
  PNG.
- Fedora's base image in `build.yaml` is bumped by hand on purpose: a new base
  invalidates that add-on's persistent system layer.
