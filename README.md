# portfolio-server

Runs [shop-finder-api](https://github.com/lecorrr/shop-finder-api) and
[booking-api](https://github.com/lecorrr/booking-api) on one small AWS EC2 instance, with
HTTPS, for as little money as possible.

```
                    internet, ports 80 and 443 only
                                 |
                       +---------v----------+
                       |       Caddy        |  HTTPS certificates, HTTP -> HTTPS
                       +----+----------+----+
          shop.<host>       |          |       booking.<host>
                 127.0.0.1:8020      127.0.0.1:8030
     +----------------------v---+  +---v-------------------------+
     | shop-finder-api (Compose) |  | booking-api (Compose)       |
     | api, worker, PostgreSQL,  |  | api, worker, beat,          |
     | MongoDB, Redis            |  | PostgreSQL, Redis           |
     +---------------------------+  +-----------------------------+
                    one t3.small: 2 vCPU, 2 GB memory + 2 GB swap
```

Each project runs with its own `compose.yaml` plus `compose.prod.yaml` (smaller worker and
MongoDB cache for a 2 GB machine), exactly as on a laptop. The databases and APIs listen on
127.0.0.1 only; the security group lets in SSH from your address and ports 80 and 443.

`setup.sh` does everything on the server, and running it again updates the server:

1. adds 2 GB of swap and installs Docker from Docker's own apt repository, with container
   log rotation;
2. clones both projects from GitHub (or pulls them), writes their `.env` with
   `make_env.py --host` the first time, and starts them with `compose.prod.yaml`;
3. starts Caddy, which gets certificates for both host names;
4. installs a nightly backup (`backup.sh`);
5. waits until both APIs answer over HTTPS and prints a summary.

Without a domain, the host names are made from the server's public IP with
[sslip.io](https://sslip.io): `shop.3-120-1-2.sslip.io` resolves to 3.120.1.2.

## What it costs

On-demand prices in Frankfurt (eu-central-1), November 2026:

| Item | Price | A month |
|---|---|---|
| t3.small instance | $0.024 an hour | about $17.50 |
| public IPv4 address (the Elastic IP) | $0.005 an hour | about $3.65 |
| 20 GB gp3 disk | about $0.10 per GB-month | about $2 |
| total | | about $23 |

A new AWS account on the Free plan gets $100 in credits, and up to $100 more for trying
some services; the Free plan ends after 6 months or when the credits run out, and it never
charges the card. Upgrade to the Paid plan before it ends to keep the server running.

## Set up the server

### 1. AWS account

Sign up at https://aws.amazon.com and choose the **Free plan**. Then, in
Billing and Cost Management, create a budget (Budgets, Create budget, "Monthly cost budget",
for example $10) so AWS emails you as the credits get used.

Pick **Europe (Frankfurt) eu-central-1** in the region menu at the top right and keep it for
all the steps below.

### 2. Key pair

EC2, Key pairs, Create key pair: name `portfolio`, type ED25519, format `.pem`. The browser
downloads `portfolio.pem`; move it into `~/.ssh` and make it private:

```bash
mv ~/Downloads/portfolio.pem ~/.ssh/
chmod 600 ~/.ssh/portfolio.pem
```

### 3. Instance

EC2, Instances, Launch instances:

| Setting | Value |
|---|---|
| Name | portfolio |
| AMI | Ubuntu Server 24.04 LTS or 26.04 LTS, 64-bit (x86) |
| Instance type | t3.small |
| Key pair | portfolio |
| Network settings | create a security group: SSH from **My IP**; HTTPS and HTTP from the internet |
| Storage | 20 GiB, gp3 |
| Advanced details, Credit specification | **Standard**: a busy CPU slows down instead of costing extra |

### 4. Elastic IP

EC2, Elastic IPs, Allocate Elastic IP address, then Actions, Associate, and pick the
instance. The address, and with it the sslip.io host names, now survives a stop and start.

### 5. Run the setup

```bash
ssh -i ~/.ssh/portfolio.pem ubuntu@ELASTIC-IP
git clone https://github.com/lecorrr/portfolio-server.git
bash portfolio-server/setup.sh
```

It takes about five minutes and ends with a summary like this:

```
== summary: setup.sh 0.1.0
  shop-finder-api  ok      https://shop.3-120-1-2.sslip.io/api/v1/docs/
  booking-api      ok      https://booking.3-120-1-2.sslip.io/api/v1/docs/
  ...
```

If the SSH connection drops halfway, connect again and run the same command; it carries
on where it is needed.

### 6. Demo data and admin users

Log out and back in once, so `docker` works without `sudo`. Then:

```bash
cd ~/apps/shop-finder-api
docker compose exec api python manage.py seed_demo
docker compose exec api python manage.py createsuperuser
cd ~/apps/booking-api
docker compose exec api python manage.py seed_demo
docker compose exec api python manage.py createsuperuser
```

## Using your own domain

Create two DNS A records pointing at the Elastic IP, `shop.example.com` and
`booking.example.com`, wait until they resolve, then:

```bash
bash ~/portfolio-server/setup.sh --domain example.com
```

The projects keep their secrets and data; only the host names change.

## Updating after a push

```bash
cd ~/portfolio-server && git pull && bash setup.sh
```

This pulls both projects, rebuilds what changed, runs the migrations and restarts the
containers that need it.

## Backups

Every night at 03:17 UTC `backup.sh` writes into `~/backups`: a `pg_dump` of each
PostgreSQL database and a `mongodump` of the catalogue, kept for 7 days. They stay on the
same disk, so they protect against mistakes, not against losing the instance; copy them off
the server (`scp`, or an S3 bucket) for that.

Restore the shop-finder database from one of them:

```bash
cd ~/apps/shop-finder-api
docker compose exec -T postgres pg_restore -U shopfinder -d shopfinder --clean --if-exists < ~/backups/shopfinder-postgres-STAMP.dump
docker compose exec -T mongo mongorestore --archive --gzip --drop < ~/backups/shopfinder-mongo-STAMP.archive.gz
```

## When something is wrong

```bash
docker ps
docker compose -f ~/apps/shop-finder-api/compose.yaml logs --tail 100 api
docker compose -f ~/portfolio-server/compose.yaml logs --tail 100 caddy
docker compose -f ~/apps/booking-api/compose.yaml exec api python manage.py doctor
free -m
```

- **Certificates.** Caddy needs port 80 open in the security group to prove it owns the
  name. Its log says when a certificate is obtained or why not.
- **SSH stopped working.** Your home IP probably changed: EC2, Security groups, edit the
  inbound SSH rule, source "My IP".
- **Out of memory.** `free -m` shows how much swap is used; if it stays high, move to a
  larger instance type (stop, Actions, Instance settings, Change instance type).

## Stopping the costs

- Stop the instance: compute stops costing, the disk and the Elastic IP do not (about $5.65
  a month).
- Remove everything: terminate the instance (its disk goes with it), then release the
  Elastic IP. Check the Billing console a day later.
