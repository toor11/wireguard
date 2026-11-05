# wireguard · Pi-hole + Unbound + WireGuard (PiVPN) on any VPS

Run your own ad-blocking DNS server on a **free-tier VPS** — no hardware needed.
Connect from anywhere (phone, laptop, family devices) with WireGuard and enjoy
network-wide ad-blocking through a **split-tunnel DNS-only VPN** that barely
uses any bandwidth.

> Based on the original *PiHole with PiVPN and Unbound on VPS* install notes,
> rewritten as a reproducible, one-command installer that works on AWS EC2,
> GCP e2-micro, Oracle/DO/Hetzner, ... anything with Debian or Ubuntu.

---

## What is this?

- [Pi-hole](https://github.com/pi-hole/pi-hole) — DNS sinkhole that blocks ads/trackers for *every* device on the tunnel (no client software needed beyond WireGuard).
- [Unbound](https://github.com/NLnetLabs/unbound) — local **recursive** DNS resolver; your DNS queries go from Pi-hole straight to the root servers, no third-party resolver sees them (privacy).
- [PiVPN](https://pivpn.io) (WireGuard) — dead-simple WireGuard VPN server + client profile manager.
- **Split-tunnel**: the VPN only routes **DNS** (port 53, for ad-blocking), not your general traffic — fast, light on bandwidth, and keeps free-tier egress at ~0.

Once connected:
- ads are blocked system-wide (browsers, apps, smart TVs, ...
- the Pi-hole dashboard is reachable at `http://<VPN-GATEWAY>/admin` — and *only* through the tunnel (it is never exposed to the internet).
- general traffic doesn't touch the VPN, so speed is unchanged.

```
                 (WireGuard, UDP 51820)
 phone/laptop ──────────────────────────────►  VPS
   DNS query            split tunnel            └─ wg0:10.100.0.0/24
   "only port 53"                                ├─ Pi-hole :53  (ad-blocking DNS  ← clients use this)
                                                 │    └─► Unbound :5335 (127.0.0.1, recursive)
                                                 │          └─► 13 root DNS servers
                                                 └─ dashboard :80 (bound locally; NO public exposure)
```

---

## Requirements

| | |
|---|---|
| VPS | 1 vCPU / 1 GB RAM is plenty (t3.micro, e2-micro, Oracle Always-Free, ...). |
| OS | Debian 11/12/13 · Ubuntu 20.04/22.04/24.04 |
| Access | root or sudo |
| Cloud firewall | **UDP 51820** open from `0.0.0.0/0` (see below) |
| Client device | WireGuard app ([all platforms](https://www.wireguard.com/install/)) |

> **Cost note (the original doc's advice):** if you were ever tempted to full-tunnel your *traffic* on AWS, don't — outbound transfer is billed per GB. This setup is DNS-only, which is why it stays free. For a full tunnel VPN, AWS Lightsail's ~$3.50 tier (1 TB/mo) is the better deal.

---

## Quick start

### 1. Create the VPS

Minimum: Debian or Ubuntu, SSH access, and open **UDP 51820** in the cloud firewall:

**AWS EC2** — in the launch wizard's *Security group* step add:
`Type: Custom UDP`, `Port range: 51820`, `Source: 0.0.0.0/0`, `Description: Wireguard`.
Tip: an Elastic IP gives you a stable VPN endpoint (free while attached).

**Google Cloud** (run once, from your workstation):
```bash
gcloud compute firewall-rules create allow-wireguard-pivpn \
  --direction=INGRESS --action=allow --rules=udp:51820 \
  --source-ranges=0.0.0.0/0 --description "WireGuard for PiVPN split-tunnel DNS"
```
Tip: promote the ephemeral external IP to static so the endpoint survives reboots:
```bash
gcloud compute addresses create my-vps-ip --region=us-central1 --addresses=<CURRENT_EXTERNAL_IP>
```

**Hetzner / DigitalOcean / Oracle / Lightsail** — allow `udp/51820` in the
provider's firewall panel (Oracle users: remember there are *two* layers —
instance firewall lists AND the host-level iptables, both must allow 51820/u.

### 2. Run the installer on the VPS

```bash
curl -fsSL https://raw.githubusercontent.com/<your-username>/wireguard/main/install.sh \
  | sudo bash -s -- --client phone --client laptop
```

Useful flags (all optional):

| Flag | Effect |
|---|---|
| `--client NAME` | extra client profiles (repeatable) |
| `--duckdns SUB TOKEN` | keep `SUB.duckdns.org` pointing at the VPS and connect clients via the hostname — survives IP changes ([section below](#dynamic-hostname-duckdns--never-chase-ip-changes)) |
| `--full-tunnel` | route **all** device traffic through the VPN instead of DNS-only ([section below](#full-tunnel-routing-all-traffic)) |
| `--web-password PASS` | fixed dashboard password |
| `--port N` | custom WireGuard port |

That's it. The installer:

1. installs Unbound and points it at `127.0.0.1:5335` (recursive, DNSSEC-anchored),
2. installs **Pi-hole** non-interactively (the v6 installer's `dialog` screens are
   automated with `expect`) and sets its **upstream = 127.0.0.1#5335**,
3. installs **PiVPN (WireGuard)** in official `--unattended` mode with
   `--use-pihole`, a clash-free `10.x.0.0/24` subnet, and
   `AllowedIPs = <VPN-GW>/32` — **split-tunnel is baked into every profile**,
4. creates one client profile per `--client NAME` (default `phone`),
5. prints your dashboard password, endpoint and next steps.

Full log: `/var/log/pivpnhole-install.log`. Keys/details: `/etc/pivpn/wireguard/setupVars.conf`.

### 3. Connect your devices

**Phone / tablet:** run on the VPS, then scan with the WireGuard app:
```bash
pivpn -qr phone                     # QR in the terminal (needs an interactive SSH session)
```
The installer also saves a PNG for every profile, so you can *copy* it instead of
scanning from the terminal:
```bash
~/configs/phone-qr.png              # generated with:  qrencode -t PNG -r phone.conf -o phone-qr.png
```

**Laptop / desktop:** copy `<user>/configs/laptop.conf` from the VPS (the
script also prints where), then WireGuard app → *Import tunnel from file* →
Activate. CLI alternative:
```bash
sudo cp laptop.conf /etc/wireguard/laptop.conf
sudo wg-quick up laptop      # disconnect with: sudo wg-quick down laptop
```

Verify: load a site — your dashboard query counter should start climbing, and
`nslookup doubleclick.net` should answer `0.0.0.0` (blocked) while
`nslookup example.com` still resolves.

**Dashboard:** `http://<VPN-GW>/admin` — e.g. `http://10.100.0.1/admin`
(the exact gateway is printed at the end of the install; it's the *first IP of
the wg subnet*, and appears as `DNS =` in every client .conf).

---

## Day-to-day commands (on the VPS)

| Command | What it does |
|---|---|
| `pivpn add -n NAME` | new client profile (`~/configs/NAME.conf`) |
| `pivpn -qr NAME` | QR code for a phone |
| `pivpn list` | clients + handshakes |
| `pivpn -c` | detailed status |
| `pivpn remove NAME` | revoke a device |
| `pihole setpassword` | change dashboard password |
| `pihole -g` | refresh adlists (gravity) |
| `pihole -up` / `pivpn -up` | update components |
| `pihole -d` | Pi-hole debug report |

Add more labels/blocklists/regex in the dashboard, they apply instantly.

---

## Adding a new device ("user")

Each device gets its own profile — that's how Pi-hole shows it by name in the
dashboard and how you can revoke one device without touching the rest.

```bash
pivpn add -n tablet            # 1. create the profile  -> ~/configs/tablet.conf
pivpn -qr tablet               # 2. scan with the WireGuard app (or copy the .conf)
```

Every new profile automatically inherits this server's settings: split-tunnel
`AllowedIPs`, the correct `Endpoint` (hostname if you use DuckDNS), static
arping via the tunnel and the current `DNS =` gateway. Kill a lost device:
`pivpn remove tablet` (and delete the tunnel from its app).

Tips:

- one profile **per device**, not per person — profiles are binary (on/off);
- the device shows up in the dashboard as `tablet.pivpn` (via PiVPN's hosts hook);
- the local config copies in `~user/configs/` are what your devices import;
  keep them `chmod 600` — a .conf contains the device private key.

---

## Dynamic hostname (DuckDNS) — never chase IP changes

WireGuard clients hard-code `Endpoint = 1.2.3.4:51820`. If a VPS IP ever
changes, all devices fail silently until re-imported. Two cures:

**A. Reserve the IP** (AWS Elastic IP / GCP reserved address / provider sticky IP).
One command on GCP, run while the *current* IP is still assigned:
```bash
gcloud compute addresses create my-vps-ip --region=<region> --addresses=$(curl -4 -s https://api.ipify.org)
```
Free while the instance stays up.

**B. Dynamic DNS** (works on *any* provider, even truly dynamic IPs):

The installer can do this for you:
```bash
| sudo bash -s -- --duckdns freesubname 1a2b3c-....duckdns-token
```
That script phase:
1. verifies your domain+token with duckdns.org,
2. installs `/etc/cron.d/pivpnhole-duckdns` (updates every 5 minutes),
3. rewrites every profile (and future ones) to `Endpoint = <SUB>.duckdns.org:<port>`.

Manual equivalent on an existing box:
```bash
# one-time: confirm the domain+token
curl "https://www.duckdns.org/update?domains=SUB&token=TOKEN"
# keep it fresh
echo '*/5 * * * * root curl -s -m 15 "https://www.duckdns.org/update?domains=SUB&token=TOKEN" >/dev/null' \
  | sudo tee /etc/cron.d/duckdns
# point existing profiles at the hostname
sudo sed -i "s|^Endpoint = .*|Endpoint = SUB.duckdns.org:51820|" /etc/wireguard/configs/*.conf
sudo sed -i "s|^pivpnHOST=.*|pivpnHOST=SUB.duckdns.org|" /etc/pivpn/wireguard/setupVars.conf
sudo sed -i "s|^Endpoint = .*|Endpoint = SUB.duckdns.org:51820|" ~/configs/*.conf
pivpn -qr phone     # re-scan each device
```
Then migrating hosts is just: stop → snapshot → new IP → cron updates DNS →
clients reconnect by themselves.

---

## Full tunnel (routing ALL traffic)

Default is DNS-only **split-tunnel** (why: free-tier egress). If you want the
VPN to carry all device traffic too:

```bash
| sudo bash -s -- --full-tunnel ...
```

What changes server-side (the script does it, and it's idempotent):
- `net.ipv4.ip_forward=1` persisted in `/etc/sysctl.d/70-pivpnhole.conf`
- `wg0.conf` gets `PostUp/PostDown` MASQUERADE + FORWARD rules
- client profiles are generated with `AllowedIPs = 0.0.0.0/0, ::0/0`

<details>
<summary>Switch manually later</summary>

```bash
# server: add NAT
sudo sed -i "/^\[Interface\]/a PostUp = iptables -t nat -A POSTROUTING -o $(ip -4 route show default | awk '{print \$5}') -j MASQUERADE ; iptables -A FORWARD -i wg0 -j ACCEPT" /etc/wireguard/wg0.conf
sudo sysctl -w net.ipv4.ip_forward=1 && echo net.ipv4.ip_forward=1 | sudo tee /etc/sysctl.d/70-pivpnhole.conf
sudo systemctl restart wg-quick@wg0
# client: widen the per-device profile
sed -i 's|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/0, ::0/0|' ~/configs/phone.conf   && pivpn -qr phone
```
(PiVPN also honors `ALLOWED_IPS` in `/etc/pivpn/wireguard/setupVars.conf` for
future profiles.)
</details>

**Cost reality-check** (repeated from the top, because full-tunnel is what makes it matter):

| Provider | Free tier egress | Note |
|---|---|---|
| Oracle Cloud | 10 TB/mo | effectively free full-tunnel |
| GCP | billed after ~1 GB | use a cloud NAT-aware region, expect charges |
| AWS EC2 | 100 GB/mo free (fringe programs) | ~$0.12/GB after → £120/mo at 1 TB |
| Lightsail $3.50/VPS | 1 TB/mo | the doc's recommendation for full tunnel |
| Hetzner CX | 20 TB/mo | cheapest scale-up |

If you only want **ad blocking** (the common case), stick with the default
split-tunnel: zero egress, zero maintenance, and the dashboard stays reachable.

---

## Security posture (by design)

- Only **UDP 51820** is open to the internet (plus SSH 22 as managed by your provider).
- Pi-hole's DNS **53** and dashboard **80/443** are **not** opened to the world,
  no matter how many interfaces FTL listens on — cloud ACL blocks the internet.
  Ad-blocking + dashboard travel only inside the encrypted tunnel.
- Unbound binds to `127.0.0.1:5335` only, so the VPS can never be used as an
  open recursive resolver.
- wg endpoints are authenticated: only profiles you generate can connect,
  and a private key in every `.conf` (keep those files safe, `chmod 600`).
- Don't open port 53 or 80 to `0.0.0.0/0` anywhere — Pi-hole would be open to DNS
  spoofing as well as heatmaps.

---

## Notes & troubleshooting

- **Static IP matters.** WireGuard clients hold an `Endpoint =`; if the VPS
  IP changes, profiles need re-exporting. Use an Elastic IP (AWS) or reserve
  the ephemeral IP (GCP) as shown above.
- **`chmod 600` on dev machines for .conf files.**
- **Pi-hole v6 installer is `dialog`-driven**; there's *no* `--unattended`
  preseed for fresh v6 installs, which is why the script automates it with
  `expect`. The dialog automation log lives at `/tmp/ph-install-automation.log`.
- **Debian 13 / unbound 1.26+**: the doc's `cache-max-size` keyword no longer
  exists; the script uses `msg-cache-size` / `rrset-cache-size` and gracefully
  drops them if `unbound-checkconf` rejects the version.
- **`/tmp/setupVars.conf permission denied`** (PiVPN): delete that file and rerun —
  `sudo rm -f /tmp/setupVars.conf`.
- **QR code PNGs that are garbage/not images**: that's `-t ANSIUTF8` (the *terminal*
  text rendering) pointed at a file. Only use it for display in a terminal; for
  files use the image type: `qrencode -t PNG -r profile.conf -o profile-qr.png`.
- **Port 53 leak panic?** Check `ss -lntu | grep :53` — FTL binds `0.0.0.0`
  locally but your provider firewall (and not the app) decides what's public.
- **IPv6**: keep it off server-side (`pivpnenableipv6=0` in setupVars.conf) unless
  your VPS has working v6; split-tunnel profile only routes v4 DNS anyway.
- **Reusing a VPS that already has Pi-hole or PiVPN**: the script detects both
  and only runs missing phases; PiVPN runs with `--use-pihole` so its DNS rules
  point at the tunnel gateway.
- **Firewall `default-allow-internal` on GCP** only exposes ports inside your
  VPC — the VPS is still closed to the internet apart from 51820 (and 22/3389/icmp defaults).

---

## Under the hood

```
install.sh
 ├── phase 0  apt: curl, unbound, expect, bind9-dnsutils, net-tools, qrencode
 ├── phase 1  /etc/unbound/unbound.conf.d/pi-hole.conf  (+ self-healing config check)
 ├── phase 2  detects GCP/AWS via metadata & prints provider firewall cmds; opens ufw if active
 ├── phase 3  Pi-hole v6 automated install (expect)     → dns.upstreams=127.0.0.1#5335
 ├── phase 4  PiVPN --unattended + --use-pihole        → AllowedIPs=<gw>/32 (or 0.0.0.0/0, ::0/0 with --full-tunnel)
 ├── phase 4b (--full-tunnel) ip_forward persist + wg0 PostUp MASQUERADE/FORWARD rules
 ├── phase 4c (--duckdns) verify token, /etc/cron.d updater, re-point profiles+setupVars to hostname
 └── phase 5  client profiles (pivpn add) + PNG QRs + dashboard password + summary
```

The installer is idempotent: safe to re-run; existing components are detected
and skipped. It intentionally doesn't do the cloud firewall for you (it can't
from inside the VM) but prints provider-specific commands.

---

## Credits

- The [Pi-hole team](https://pi-hole.net), the [Unbound NLnet Labs] devs, and the
  [PiVPN](https://github.com/pivpn/pivpn) maintainers.
- Unbound config from the official Pi-hole guide: [docs.pi-hole.net/guides/unbound](https://docs.pi-hole.net/guides/unbound/).



## License

MIT — see [LICENSE](LICENSE).
