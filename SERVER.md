# Setting up the workshop server (clean Ubuntu VM)

From a clean Ubuntu VM to a running workshop. Allow about an hour; most of it is waiting for the image build
and the data copy. Do it the day before, not in the morning of the workshop.

**What you need**

- An Ubuntu VM (22.04 or 24.04) with a public IP address, and ports **80** and **443** open to the internet.
  Other ports work too: set them in `config.yml` (step 4).
- Size: **8 CPU cores, 32 GB memory, 30 GB disk** for 15 participants (each uses about 0.5–1 GB while working;
  the limit is 2 GB). 16 GB memory is the bare minimum for 15 people.
- The dataset file `synthea-covid19-10k.duckdb` (1.2 GB) from a laptop where the workshop already runs
  (`run/data/`), or 13 GB of memory on the VM to build it there (step 5).
- The list of participant names.

Commands below are typed on the VM (log in with `ssh <user>@<ip address>`), unless it says *on your laptop*.

## 1. Install Docker and git

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/sophiedkk/workshop-omop.git
cd workshop-omop
bash server/install-ubuntu.sh
```

Then **log out and log back in** (so your account may use Docker), and check:

```bash
cd workshop-omop
docker info >/dev/null && echo ok
```

## 2. Build the image

```bash
./ws build
```

Takes 5–15 minutes the first time (R and all packages).

## 3. Check the ports

The workshop uses the ports from `config.yml` (default 80 and 443). Check that nothing else uses them:

```bash
sudo ss -ltnp | grep -E ':(80|443) ' || echo "free"
```

The ports must also be open in the cloud firewall (Azure: the network security group of the VM; IT did this).
Ubuntu's own firewall is usually off; if `sudo ufw status` says *active*: `sudo ufw allow 80,443/tcp`.

## 4. Configure: config.yml

```bash
cp config.example.yml config.yml
nano config.yml
```

Set at least:

```yaml
participants:
  - Ana de Vries
  - Ben Jansen
  # ... one name per line
address: auto        # the VM's public IP address, looked up automatically (or write it, e.g. 20.1.2.3)
https_port: 443
http_port: 80
tls: auto            # free certificate from Let's Encrypt
```

Check what participants will use:

```bash
./ws address
```

It prints something like `Participants open: https://20-1-2-3.sslip.io`. That is the address for the slides and
the login cards. (A certificate is issued for a name, not a bare IP address; `sslip.io` turns the IP address into a
name. Typing `http://20.1.2.3` also works: it redirects there.)

## 5. The dataset

Either copy it from your laptop (*on your laptop*, in the repository folder):

```bash
scp run/data/synthea-covid19-10k.duckdb <user>@<ip address>:workshop-omop/run/data/
```

or build it on the VM (needs about 13 GB of free memory, takes a few minutes):

```bash
./ws prepare-data
```

Check: `ls -lh run/data/` shows `synthea-covid19-10k.duckdb` of about 1.2 GB.

## 6. Participants and passwords

```bash
./ws setup
```

This creates an account for every name in `config.yml`, plus the facilitator account `admin`. It prints the
usernames. Then:

- **Login details for each participant:** `run/handouts/<username>.txt` holds their name, the address, their
  username and password, ready to paste into an e-mail or a Teams message. Copy the folder to your laptop
  (*on your laptop*: `scp -r <user>@<ip address>:workshop-omop/run/handouts .`).
- **Printed instead:** `run/handouts/all.html` is a sheet with all login cards, to print and cut.
- **Your own login:** `cat run/handouts/admin.txt`.

## 7. Start

```bash
./ws up
```

The first start gets the certificate from Let's Encrypt; give it a minute. Then, from your laptop's browser:

1. Open the address from step 4: you see the Hanze login page, with a valid padlock.
2. Log in as `admin`: the facilitator page.
3. In a private window, log in with one participant card: the tutorial, with part 2 to 5 locked.
4. As admin, press **Open** for part 2: it appears for the participant within a few seconds.

## 8. Test the whole tool chain

```bash
./ws test                     # the rules: gating, answers, feedback
./ws setup --reset            # start the end-to-end test from a clean state
./ws e2e                      # real browsers: login, live opening, answers, feedback, every exercise (~5 min)
./ws setup --reset            # clean again for the workshop
```

`./ws e2e` logs in as the first two participants on the list and as admin, answers some questions and opens every
part; `./ws setup --reset` afterwards removes all of that.

## On the day

- After a restart of the VM, the workshop starts by itself (Docker restarts it). If not: `cd workshop-omop && ./ws up`.
- Before the session: `./ws setup --reset` clears all test answers and releases. Passwords stay the same.
- During the session: the facilitator page shows who is online, opens parts and shows feedback.
- `./ws ps` lists the running containers (one per participant who is logged in); `./ws logs` shows the logs.

## Changes and problems

| You want to... | Do |
|---|---|
| Add or rename participants | Edit `config.yml`, then `./ws setup --fresh` (everyone gets new passwords and new cards). |
| Change the address, ports or HTTPS mode | Edit `config.yml`, then `./ws setup --config` and `./ws up`. |
| Get the latest version of the workshop | `git pull`, `./ws build`, `./ws up`. |
| Clear answers after a rehearsal | `./ws setup --reset` |
| Stop everything | `./ws down` |

- **No padlock / certificate error.** Let's Encrypt must reach the VM on port 80 (or 443) from the internet: check
  the cloud firewall. `./ws logs caddy` shows why it failed. If it keeps failing (for example because of Let's
  Encrypt's rate limits for `sslip.io`), get a certificate with certbot
  (`sudo apt-get install -y certbot && sudo certbot certonly --standalone -d <name from ./ws address>` while the
  workshop is stopped), and set `tls: files` in `config.yml`.
- **Only other ports are allowed.** Set `https_port` and `http_port` in `config.yml`. A Let's Encrypt certificate
  (`tls: auto`) needs port 80 or 443 reachable from the internet; with neither, use `tls: files` with a certificate
  obtained elsewhere.
- **A participant's page hangs.** Ask them to reload the page. If that does not help: they sign out (bottom of the
  list on the left) and sign in again; this gives them a fresh session. Their answers are kept.
- **The server was restarted and the workshop is not back.** `cd workshop-omop && ./ws up`.
