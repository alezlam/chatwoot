# Chatwoot fork — Onboarding

This repo is a fork of Chatwoot (`alezlam/chatwoot`, base branch **`develop`**) that replaces the Shopee Seller Management tool. On top of upstream it adds a **WhatsApp Web (QR code) provider** backed by a Baileys sidecar, with history import, contact names and profile photos. It runs on **Railway** (app) + **Supabase** (Postgres + file storage).

The repo's `CLAUDE.md` (a symlink to `AGENTS.md`) holds the deeper notes: architecture, deployment and gotchas. Read its "This Fork" section after this guide.

---

## 1. Access to request

| What | Who grants it | Why |
| --- | --- | --- |
| GitHub collaborator on `alezlam/chatwoot` | Alex | Clone, push, merge to `develop` |
| Railway project **`chatwoot`** (workspace "aspoofer's Projects") | Alex | Deploys, logs, production variables (secrets live here) |
| Supabase org **"aspoofer0224's Org"**, project **`chatwoot`** (`gksrosykxmeujexmwrpm`) | Alex | Database, Storage bucket, S3 keys |
| Production Chatwoot login | Alex, via `/super_admin` → Users | Test on https://web-production-cf4d6.up.railway.app |

Secrets are **never** in the repo or in this doc. Read them from Railway variables once you have access. Alex keeps a copy of the Supabase `postgres` password and S3 keys in a password store.

---

## 2. Local setup (macOS, Apple Silicon)

### 2.1 Toolchain

Use **native ARM Homebrew** (`/opt/homebrew`). An Intel Homebrew in `/usr/local` makes rbenv build an x86 Ruby, and native gems then fail.

```bash
# Homebrew (skip if `which brew` already prints /opt/homebrew/bin/brew)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew install rbenv ruby-build libyaml openssl@3 libpq nvm overmind
```

Add to `~/.zshrc`, then open a new terminal:

```bash
eval "$(rbenv init - zsh)"
export NVM_DIR="$HOME/.nvm"; source "$(brew --prefix nvm)/nvm.sh"
```

```bash
rbenv install 3.4.4          # matches .ruby-version
nvm install 24 && nvm alias default 24
corepack enable              # provides pnpm 10 from package.json
```

You also need **Docker Desktop** (or another Docker runtime) for Postgres and Redis.

### 2.2 Clone

```bash
gh repo clone alezlam/chatwoot
cd chatwoot
git checkout develop
git remote add upstream https://github.com/chatwoot/chatwoot.git   # to pull upstream fixes later
```

### 2.3 Databases (Docker)

Postgres needs the **pgvector** extension, so use the image the repo's `docker-compose.yaml` uses. Port 5433 avoids clashing with any local Postgres.

```bash
docker run -d --name chatwoot-postgres -p 5433:5432 \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -v chatwoot-pgdata:/var/lib/postgresql/data --restart unless-stopped pgvector/pgvector:pg16

docker run -d --name chatwoot-redis -p 6379:6379 --restart unless-stopped redis:7-alpine
```

### 2.4 `.env`

```bash
cp .env.example .env
```

Then set these keys in `.env`:

| Key | Local value |
| --- | --- |
| `SECRET_KEY_BASE` | output of `openssl rand -hex 64` |
| `FRONTEND_URL` | `http://localhost:3000` |
| `REDIS_URL` | `redis://localhost:6379` |
| `POSTGRES_HOST` | `localhost` |
| `POSTGRES_PORT` | `5433` (add the line under `POSTGRES_HOST`) |
| `POSTGRES_USERNAME` | `postgres` |
| `POSTGRES_PASSWORD` | `postgres` |
| `BAILEYS_API_KEY` | output of `openssl rand -hex 32` (any value; Rails and the sidecar read the same `.env`) |
| `BAILEYS_API_URL` | `http://localhost:4100` |
| `BAILEYS_HISTORY_DAYS` | optional, default `30` (`0` disables history import) |
| `LETTER_OPENER` | optional: `true` opens outgoing emails in the browser instead of sending |

`.env` is gitignored. Never commit it.

### 2.5 Install and set up the database

```bash
bundle config set --local build.pg "--with-pg-config=$(brew --prefix libpq)/bin/pg_config"
bundle install
pnpm install
(cd baileys && pnpm install)        # the sidecar has its own package.json
bundle exec rails db:chatwoot_prepare   # creates DBs, loads schema, seeds sample data
```

### 2.6 Run

```bash
overmind start -f Procfile.dev
```

This starts four processes: `backend` (Rails :3000), `worker` (Sidekiq), `vite` (:3036, hot reload) and `baileys` (WhatsApp sidecar :4100). Stop with Ctrl+C or `overmind quit`.

- App: http://localhost:3000. Seed login: `john@acme.inc` / `Password1!` (SuperAdmin; `/super_admin` for the admin console)
- To test WhatsApp Web locally: Settings → Inboxes → Add → WhatsApp → **WhatsApp Web**, then scan the QR with a **test number** (unofficial connection, so bans are possible).

### 2.7 Lint and tests

```bash
pnpm eslint                        # JS/Vue
bundle exec rubocop -a             # Ruby
bundle exec rspec spec/path_spec.rb
pnpm test
```

---

## 3. Production environment variables

All of these are already set in Railway. This table is for understanding them; the values themselves live in Railway.

### `web` and `worker` (identical sets)

| Variable | Value / source | Secret |
| --- | --- | --- |
| `RAILS_ENV` | `production` | |
| `NODE_ENV` | `production` | |
| `RAILS_LOG_TO_STDOUT` | `true` | |
| `FRONTEND_URL` | `https://web-production-cf4d6.up.railway.app` (change when a custom domain is added) | |
| `ENABLE_ACCOUNT_SIGNUP` | `false` | |
| `SECRET_KEY_BASE` | random 128-hex | ✅ |
| `DATABASE_URL` | Supabase **session pooler** as role `chatwoot_app`: `postgres://chatwoot_app.gksrosykxmeujexmwrpm:<pw>@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres?sslmode=require&schema_search_path=chatwoot,extensions` | ✅ |
| `REDIS_URL` | `${{Redis.REDIS_URL}}` (Railway reference) | |
| `ACTIVE_STORAGE_SERVICE` | `s3_compatible` | |
| `STORAGE_BUCKET_NAME` | `chatwoot` (private Supabase bucket) | |
| `STORAGE_REGION` | `ap-southeast-1` | |
| `STORAGE_ENDPOINT` | `https://gksrosykxmeujexmwrpm.storage.supabase.co/storage/v1/s3` | |
| `STORAGE_FORCE_PATH_STYLE` | `true` | |
| `STORAGE_ACCESS_KEY_ID` | Supabase Storage S3 key | ✅ |
| `STORAGE_SECRET_ACCESS_KEY` | Supabase Storage S3 secret | ✅ |
| `BAILEYS_API_URL` | `http://baileys.railway.internal:4100` (private network) | |
| `BAILEYS_API_KEY` | shared secret, **same value** as on `baileys` | ✅ |

### `baileys` (WhatsApp sidecar)

| Variable | Value | Secret |
| --- | --- | --- |
| `BAILEYS_API_KEY` | same as web/worker | ✅ |
| `PORT` / `BAILEYS_PORT` | `4100` (Railway's health check probes `$PORT`) | |
| `BAILEYS_SESSIONS_DIR` | `/data/baileys` (on the service's volume) | |
| `BAILEYS_HISTORY_DAYS` | unset = 30 days of history on first link | |

### `Redis`

Managed by Railway (`REDIS_URL`, `REDISHOST`, `REDISPORT`, `REDISUSER`, `REDISPASSWORD`). Don't edit these.

---

## 4. Production infrastructure

| Piece | Where | Notes |
| --- | --- | --- |
| `web` | Railway, Singapore | `docker/Dockerfile`; pre-deploy `bundle exec rails db:chatwoot_prepare`; start `bundle exec rails s -b 0.0.0.0`; health `/api`; IPv6 egress on |
| `worker` | Railway, Singapore | same image; `bundle exec sidekiq -C config/sidekiq.yml`; IPv6 egress on |
| `baileys` | Railway | root dir `baileys/`; volume `/data` (WhatsApp logins); **must stay 1 replica** |
| Redis | Railway, Singapore | job queue, ActionCable, locks |
| Postgres | Supabase `gksrosykxmeujexmwrpm`, Singapore | all Chatwoot tables in schema **`chatwoot`**, never `public` (Supabase's API exposes `public`) |
| Files | Supabase Storage bucket `chatwoot` | via S3 API |

Settings were applied through Railway's API, not repo config files: Railway rejects `railway.toml` for new services.

---

## 5. Deploying

Pushing to `develop` does **not** auto-deploy (the fork isn't visible to Railway's GitHub App). After merging to `develop`, deploy each changed service at the new commit:

```bash
npm install -g --allow-scripts=@railway/cli @railway/cli && railway login && railway link   # once
```

```bash
railway api 'mutation($s:String!,$e:String!,$c:String){ serviceInstanceDeployV2(serviceId:$s, environmentId:$e, commitSha:$c) }' \
  --variables "{\"s\":\"<service-id>\",\"e\":\"3b669258-9fa4-41a0-ae67-00e530977e44\",\"c\":\"$(git rev-parse origin/develop)\"}"
```

| Service | id |
| --- | --- |
| web | `6a97cf6e-24d0-4cf6-b2d2-58abad0376c2` |
| worker | `fb233090-5fce-4c87-a073-4f672bcaab2b` |
| baileys | `c2ab4e69-fde0-4d52-b8db-375c27f7a305` |

Order: deploy **`web` before `baileys`** whenever the sidecar sends something new. A `baileys` deploy drops WhatsApp for a few seconds; it reconnects by itself without a re-scan.

Check status and logs: `railway status`, `railway logs --service <name>`.

---

## 6. Gotchas

- **Railway start commands run without a shell**: `$PORT` is not expanded, so Rails reads `PORT` itself.
- **Region matters**: app services must stay in Singapore next to Supabase. In the US region every query cost about 190 ms and lists hit the 15 s request timeout.
- **IPv6 egress** must stay on for `worker`: WhatsApp's profile-photo CDN is IPv6-only from Railway.
- **WhatsApp history is sent once, on a fresh link.** Re-importing means unlink + re-scan. Imported chats land **resolved**, so switch the conversation filter from Open to Resolved/All to see them.
- **Hidden-number contacts** (`LI.<id>`): WhatsApp hides the number for contacts not saved on the phone. They switch to a name or phone number once WhatsApp reveals it.
- **Unofficial API**: WhatsApp can ban numbers used for bulk or automated sending. Test with spare numbers.
- First production deploy on an empty database: `worker` crashes until `web`'s pre-deploy has created the tables. Redeploy `worker` after.

---

## 7. Open items

- Imported chats as **open** instead of resolved (product decision pending)
- Friendlier label than `LI.<id>` for hidden-number contacts
- **Custom domain**: Chrome flags the `*.up.railway.app` URL as "Dangerous"
- **SMTP**: needed for agent invites and password-reset emails
- Message history beyond 30 days (Baileys on-demand history fetch), and history import for other channels
