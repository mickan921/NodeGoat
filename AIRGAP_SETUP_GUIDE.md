# NodeGoat Airgapped Proxmox Setup Guide

This guide explains how to package and run NodeGoat on an airgapped Proxmox VM.
The intended target is a blank Ubuntu 24.04 amd64 VM with no internet access.

NodeGoat is intentionally vulnerable. Keep it isolated inside the lab network.

## What NodeGoat Does

NodeGoat is an intentionally vulnerable Node.js and MongoDB training application
from OWASP. It is designed for learning how common web security issues show up
in a real application, especially the OWASP Top 10 categories.

The application has two connected learning surfaces:

- A vulnerable demo app that users can log into and exercise.
- A tutorial at `/tutorial` that explains the vulnerability category, points to
  the relevant vulnerable behavior, and describes possible fixes.

In this airgapped setup, the offline VM is the classroom or lab runtime. All
source changes, package downloads, image builds, and bundle creation happen on
the internet-connected Ubuntu builder. The offline VM only installs from the
bundle you transfer into the lab.

## Architecture

- Online builder: Ubuntu 24.04 amd64 machine with internet access. It clones this repo, builds the NodeGoat Docker image, pulls MongoDB, downloads Docker Engine packages and dependencies, and creates one transfer bundle.
- Offline target: Ubuntu 24.04 amd64 VM in Proxmox. It installs Docker only from the transferred bundle, loads prebuilt images, and starts NodeGoat with Docker Compose.
- Runtime: Docker Compose starts `nodegoat-web:1.3.0-airgap` and `mongo:4.4`.
- Database behavior: the installer resets and seeds MongoDB when deployed. Normal container restarts do not reseed; use `reset-db.sh` when you want to wipe training progress and return to defaults.

Runtime components:

| Component | Purpose | Offline source |
| --- | --- | --- |
| `nodegoat-web:1.3.0-airgap` | Node.js web application listening on port `4000`. | Built by `airgap/build-bundle.sh` and loaded from `images/nodegoat-images.tar.gz`. |
| `mongo:4.4` | MongoDB database used by NodeGoat. | Pulled by the builder and loaded from `images/nodegoat-images.tar.gz`. |
| Docker Engine and Compose plugin | Runs the app and database containers on the blank VM. | Installed from the transferred local `debs/` repository. |
| Mongo volume `nodegoat-airgap_nodegoat-mongo-data` | Stores seeded users and lab progress. | Created on the offline VM by Compose. |

Default users:

| Username | Password |
| --- | --- |
| `admin` | `Admin_123` |
| `user1` | `User1_123` |
| `user2` | `User2_123` |

## How To Use NodeGoat After Install

After `sudo ./install-airgap.sh` completes, open the app from a browser inside
the same isolated lab network:

```text
http://<VM-IP>:4000/
```

Use `http://localhost:4000/` only from inside the VM itself. From another lab
machine, replace `<VM-IP>` with the Proxmox VM address.

Common pages:

| URL | Login required | Purpose |
| --- | --- | --- |
| `/` | No | Welcome page. |
| `/login` | No | Sign in with seeded users. |
| `/signup` | No | Create an additional lab user. |
| `/tutorial` | No | Tutorial home, starts at A1 Injection. |
| `/tutorial/a1` through `/tutorial/a10` | No | OWASP Top 10 tutorial pages. |
| `/tutorial/redos` | No | ReDoS training page. |
| `/tutorial/ssrf` | No | SSRF training page. |
| `/dashboard` | Yes | Main logged-in application page. |
| `/profile` | Yes | User profile workflow. |
| `/contributions` | Yes | Contributions workflow. |
| `/allocations/<userId>` | Yes | Allocation workflow for a seeded user ID. |
| `/memos` | Yes | Memo workflow. |
| `/research` | Yes | Research workflow. |
| `/benefits` | Yes | Benefits workflow. |
| `/logout` | Yes | End the current session. |

Recommended training flow:

1. Open `/tutorial` and pick a vulnerability category.
2. Log into the app as `user1` or `user2`.
3. Exercise the matching vulnerable workflow in the app.
4. Log in as `admin` when a lesson needs admin behavior.
5. Inspect the source code on the online builder when you want to study or fix
   the vulnerability.
6. Rebuild the bundle on the online builder and redeploy to the offline VM when
   you want the lab to run your modified code.
7. Run `sudo ./reset-db.sh` before a new class or exercise if you want the
   original users and sample data back.

Important usage notes:

- NodeGoat intentionally contains vulnerable code and old dependencies. Do not
  expose it to the internet or a production network.
- The tutorial is reachable without logging in, but the vulnerable demo
  workflows generally require a login.
- New users created through `/signup` live in the MongoDB volume until you reset
  the database.
- Normal container restarts preserve training progress. Only install and
  `reset-db.sh` intentionally wipe and reseed MongoDB.
- If the browser cannot reach the app, first run `sudo ./diagnose-airgap.sh` on
  the VM, then check the Proxmox bridge, VM IP address, and any firewall rules.

## Online Builder Steps

Use an internet-connected Ubuntu 24.04 amd64 machine. Build on the same Ubuntu release and CPU architecture as the offline VM so apt resolves the right packages.

1. Clone or hydrate the repo.

   ```bash
   git clone https://github.com/mickan921/NodeGoat.git
   cd NodeGoat
   ```

2. Install Docker Engine on the online builder and make sure Docker works.

   ```bash
   sudo apt-get update
   sudo apt-get install -y ca-certificates curl gnupg dpkg-dev
   sudo install -m 0755 -d /etc/apt/keyrings
   curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
   sudo chmod a+r /etc/apt/keyrings/docker.gpg
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
   sudo apt-get update
   sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
   docker version
   docker compose version
   ```

3. Build the airgap bundle.

   ```bash
   chmod +x airgap/*.sh
   ./airgap/build-bundle.sh
   ```

4. Confirm the output exists.

   ```bash
   ls -lh dist/nodegoat-airgap-ubuntu24.04-amd64.tar.gz
   ls -lh dist/nodegoat-airgap-ubuntu24.04-amd64.tar.gz.sha256
   ```

5. Transfer both files to the offline VM using your approved removable media or transfer process:

   ```text
   dist/nodegoat-airgap-ubuntu24.04-amd64.tar.gz
   dist/nodegoat-airgap-ubuntu24.04-amd64.tar.gz.sha256
   ```

## Rebuilding After Source Changes

Use this workflow when you modify NodeGoat source code, patch a vulnerability for
class discussion, change the Dockerfile, or update the airgap scripts.

1. Make and test the code change on the online Ubuntu 24.04 amd64 builder.
2. Rebuild the bundle:

   ```bash
   ./airgap/build-bundle.sh
   ```

3. Transfer the new files to the offline VM:

   ```text
   dist/nodegoat-airgap-ubuntu24.04-amd64.tar.gz
   dist/nodegoat-airgap-ubuntu24.04-amd64.tar.gz.sha256
   ```

4. Extract the new bundle into a new directory on the offline VM.
5. Run the installer again:

   ```bash
   sudo ./install-airgap.sh
   ```

The installer intentionally resets and seeds MongoDB on deploy so each rebuilt
lab starts from a known state. If you need to preserve a class's in-progress
database, do not rerun `install-airgap.sh` until you have exported or otherwise
backed up the Mongo volume.

## Offline VM Install Steps

Run these commands on the airgapped Ubuntu 24.04 amd64 VM.

1. Put the bundle in a working directory.

   ```bash
   mkdir -p ~/nodegoat-airgap
   cd ~/nodegoat-airgap
   ```

2. Verify the transferred tarball if the `.sha256` file is present.

   ```bash
   sha256sum -c nodegoat-airgap-ubuntu24.04-amd64.tar.gz.sha256
   ```

3. Extract the bundle.

   ```bash
   tar -xzf nodegoat-airgap-ubuntu24.04-amd64.tar.gz
   cd nodegoat-airgap-ubuntu24.04-amd64
   ```

4. Install and start NodeGoat.

   ```bash
   sudo ./install-airgap.sh
   ```

5. Run diagnostics after install.

   ```bash
   sudo ./diagnose-airgap.sh
   ```

6. Open NodeGoat from another lab machine that can reach the VM:

   ```text
   http://<VM-IP>:4000/
   ```

7. Log in with a seeded account, for example:

   ```text
   user1 / User1_123
   ```

8. Open the tutorial:

   ```text
   http://<VM-IP>:4000/tutorial
   ```

9. For an instructor sanity check, verify these pages load:

   ```text
   http://<VM-IP>:4000/login
   http://<VM-IP>:4000/tutorial/a1
   http://<VM-IP>:4000/dashboard
   ```

   `/dashboard` should redirect to login when you are signed out and should show
   the app after a successful login.

## Reset Seeded Data

The selected behavior is a reproducible training environment. To reset MongoDB back to the seed users and sample data:

```bash
cd ~/nodegoat-airgap/nodegoat-airgap-ubuntu24.04-amd64
sudo ./reset-db.sh
```

This stops the Compose stack, removes the MongoDB volume, seeds the default data, restarts the stack, and waits for `http://localhost:4000/login`.

## What The Bundle Contains

After extraction, the bundle should contain:

| Path | Purpose |
| --- | --- |
| `install-airgap.sh` | Offline installer. Installs Docker from local `.deb` files, loads images, starts NodeGoat. |
| `diagnose-airgap.sh` | Read-only troubleshooting helper. |
| `reset-db.sh` | Removes Mongo data and restarts the seeded environment. |
| `compose.airgap.yml` | Runtime Compose file. Uses only preloaded images. |
| `debs/` | Local apt repository with Docker Engine, Compose plugin, and dependencies. |
| `images/nodegoat-images.tar.gz` | Docker image archive for NodeGoat and MongoDB. |
| `SHA256SUMS` | Bundle file integrity checks. |
| `docs/AIRGAP_SETUP_GUIDE.md` | Copy of this guide. |
| `source/nodegoat-source.tar.gz` | Source snapshot for audit/reference. |

The runtime Compose file must not contain `build:`. The offline VM must never need to pull from Docker Hub or npm.

## Project Layout For Maintainers

Use this map when you are changing NodeGoat on the online builder before
creating a new airgap bundle.

| Path | Purpose |
| --- | --- |
| `server.js` | NodeGoat application entrypoint. |
| `package.json` and `package-lock.json` | Node.js dependencies and npm scripts. The airgap image build uses `npm ci`. |
| `config/env/all.js` | Default app configuration, including port `4000`. |
| `app/routes/` | Express route handlers for login, tutorial, dashboard, profile, contributions, allocations, memos, research, and benefits. |
| `app/views/` | Swig templates rendered by the application. |
| `app/views/tutorial/` | Tutorial pages for OWASP Top 10, ReDoS, and SSRF lessons. |
| `app/data/` | Data access helpers for MongoDB-backed workflows. |
| `artifacts/db-reset.js` | Seed/reset script used by the installer and reset helper. |
| `Dockerfile` | Builds the offline NodeGoat web image. |
| `docker-compose.yml` | Upstream/development Compose file. Do not use it on the offline VM. |
| `airgap/compose.airgap.yml` | Offline Compose file. Uses only preloaded images and `pull_policy: never`. |
| `airgap/build-bundle.sh` | Online builder script. |
| `airgap/install-airgap.sh` | Offline installer. |
| `airgap/diagnose-airgap.sh` | Offline diagnostic helper. |
| `airgap/reset-db.sh` | Offline database reset helper. |

Useful online-builder development commands:

```bash
npm ci
npm start
npm run db:seed
docker build -t nodegoat-web:local-check .
docker build --platform linux/amd64 -t nodegoat-web:amd64-check .
docker compose -f airgap/compose.airgap.yml config
```

For the airgapped VM, do not run `npm install`, `npm ci`, `docker build`, or the
upstream `docker-compose.yml`. Those operations either need internet or rebuild
runtime artifacts that should already be inside the transferred bundle.

## Resilient Installer Behavior

The offline installer is intentionally defensive:

- It checks Ubuntu release and architecture before doing work.
- It verifies required bundle files before installing anything.
- It checks `SHA256SUMS` before trusting the bundle.
- It configures apt to use only the local `debs/` repository.
- It captures logs in `logs/install-YYYYMMDD-HHMMSS.log`.
- On failure, it prints the failing command, step, log path, last log lines, and the diagnostic command to run.
- If apt reports missing packages, it tries to parse the missing package names and prints a builder command to run on the internet-connected machine.
- It resets and seeds MongoDB during install only; later container restarts preserve the current training state.

Example missing dependency recovery:

```text
On the internet-connected Ubuntu 24.04 amd64 builder, run:
  ./airgap/build-bundle.sh --include-packages "missing-package-name"

Then transfer the rebuilt tarball back here, extract it, and rerun:
  sudo ./install-airgap.sh
```

## Troubleshooting

| Problem | What it means | What to bring from internet machine |
| --- | --- | --- |
| `SHA256SUMS` fails | Bundle was edited, corrupted, or partially copied. | Recopy `nodegoat-airgap-ubuntu24.04-amd64.tar.gz` and its `.sha256` file. |
| Missing `debs/Packages.gz` | The local apt repository was not bundled or extraction is incomplete. | Rebuild with `./airgap/build-bundle.sh` and recopy the full tarball. |
| Apt says `Unable to locate package` | A required `.deb` is absent from the local repository. | Run the printed `./airgap/build-bundle.sh --include-packages "..."` command on the builder. |
| Apt mentions `Temporary failure resolving`, `Could not resolve`, or `Network is unreachable` | Apt tried to reach internet or a package source is not fully local. | Rebuild the bundle and verify the offline installer uses only the extracted `debs/` directory. |
| Docker service does not start | Docker package install succeeded but daemon failed to launch. | Run `sudo ./diagnose-airgap.sh`; if logs show missing system packages, rebuild with `--include-packages`. |
| Missing Docker image | `nodegoat-images.tar.gz` did not load correctly or has wrong tags. | Rebuild and recopy `images/nodegoat-images.tar.gz` inside the full bundle. |
| Compose tries to pull from internet | The wrong Compose file is being used or required images are missing. | Use `compose.airgap.yml`; rebuild and recopy the image tarball. |
| Port `4000` already in use | Another process is using the host port. | Stop that process, or edit `compose.airgap.yml` to map a different host port. |
| NodeGoat starts but login fails | Seed data did not reset or MongoDB is unhealthy. | Run `sudo ./reset-db.sh`, then `sudo ./diagnose-airgap.sh` if it still fails. |
| Browser cannot reach the app | VM firewall, Proxmox networking, or wrong VM IP. | No package required; check VM IP, firewall, and Proxmox bridge/network settings. |

## Diagnostic Commands

Run this first when something looks wrong:

```bash
sudo ./diagnose-airgap.sh
```

Useful Docker commands:

```bash
sudo docker compose -f compose.airgap.yml ps
sudo docker compose -f compose.airgap.yml logs --tail=120
sudo docker image ls
sudo systemctl status docker --no-pager
```

Useful network checks:

```bash
ss -ltnp '( sport = :4000 )'
curl -v http://localhost:4000/login
```

## Rebuilding After A Missing Package Error

If the offline installer prints missing packages, do not try to install them on the airgapped VM from the internet. Instead:

1. Write down or copy the exact command printed by the installer.
2. Go back to the internet-connected Ubuntu 24.04 amd64 builder.
3. Run the command, for example:

   ```bash
   ./airgap/build-bundle.sh --include-packages "package-a package-b"
   ```

4. Transfer the new tarball and checksum to the offline VM.
5. Extract the new bundle.
6. Rerun:

   ```bash
   sudo ./install-airgap.sh
   ```

The scripts prefer clear recovery instructions over clever auto-repair because the offline VM must not depend on internet access.
