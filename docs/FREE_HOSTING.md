# Free Hosting Guide — YOUPI PG live at ₹0

YOUPI PG runs 5 public services, a SQLite database on disk and long-lived payment sessions. It needs an
always-on VM with persistent storage. "Serverless" free tiers can't run it.

## 1. Pick a host

| Host | Free allowance | Fits YOUPI PG? | Notes |
| :--- | :--- | :--- | :--- |
| **Oracle Cloud Always Free** | ARM VM up to 4 OCPU / 24 GB RAM, 200 GB disk, forever | ✅ **Recommended** | Card needed for identity check, not charged |
| Google Cloud Free Tier | 1 × e2-micro (1 GB RAM), 30 GB disk, US regions only | ⚠️ Works, tight on RAM | Add 1–2 GB swap |
| Your own PC + Cloudflare Tunnel | Free | ⚠️ Works while the PC is on | Needs a domain on Cloudflare |
| Render / Railway / Vercel / Netlify free | — | ❌ | One port only, sleeps when idle, disk wiped on restart (SQLite data lost) |

## 2. Domain (also free)

No domain? The installer uses **sslip.io**, a free wildcard DNS service. `pay.1-2-3-4.sslip.io` resolves to `1.2.3.4`,
so all 5 hostnames work at once with real HTTPS.

| Hostname | Service | Port |
| :--- | :--- | :--- |
| `pay.<ip>.sslip.io` | Checkout portal + `youpi.js` | 7000 |
| `pay-api.<ip>.sslip.io` | Payment API | 6100 |
| `pay-admin.<ip>.sslip.io` | Merchant admin | 6001 |
| `pay-gmail.<ip>.sslip.io` | Gmail OAuth / observer | 6003 |
| `pay-store.<ip>.sslip.io` | Demo store (optional) | 5000 |

Own domain later? Add 5 `A` records (`pay`, `pay-api`, `pay-admin`, `pay-gmail`, `pay-store`) pointing at the VM IP,
then re-run the installer with `DOMAIN=yourdomain.com` (delete `/opt/youpi/.env` first so the URLs are regenerated).

## 3. Create the Oracle VM (≈10 min)

1. Sign up at <https://www.oracle.com/cloud/free/>. Pick a home region near your customers (e.g. Mumbai / Hyderabad).
2. **Compute → Instances → Create instance**
   - Image: **Canonical Ubuntu 24.04**
   - Shape: **Ampere VM.Standard.A1.Flex**, 1–4 OCPU, 6–24 GB RAM (all within Always Free)
   - Networking: keep "Assign a public IPv4 address" on
   - SSH keys: upload your public key, or download the generated one
3. **Open ports 80 and 443**: Instance → Subnet → Default Security List → **Add Ingress Rules**
   - Source CIDR `0.0.0.0/0`, TCP, destination port `80`
   - Source CIDR `0.0.0.0/0`, TCP, destination port `443`

> "Out of capacity" for A1? Retry later or in another availability domain, or use the
> `VM.Standard.E2.1.Micro` shape (also Always Free, 1 GB RAM — add swap, see §6).

## 4. Install YOUPI PG (one command)

```bash
ssh ubuntu@<VM_PUBLIC_IP>
curl -fsSL https://raw.githubusercontent.com/thinkdigital8/YouPI-PG-gateway/main/deploy/free-vm/setup.sh | sudo bash
```

What the script does:

| Step | Action |
| :--- | :--- |
| 1 | Installs Node.js 22 and Caddy |
| 2 | Clones the repo into `/opt/youpi` under a dedicated `youpi` user |
| 3 | Writes `/opt/youpi/.env` with random secrets and the public URLs |
| 4 | `npm ci` + `npm run db:setup` |
| 5 | Registers `youpi.service` (systemd: auto-start on boot, restart on crash) |
| 6 | Configures Caddy: HTTPS certificates + reverse proxy for the 5 hostnames |
| 7 | Opens 80/443 in the VM firewall (Oracle images block them by default) |

At the end it prints the live URLs. Optional overrides: `DOMAIN`, `PREFIX`, `BRANCH`, `ACME_EMAIL`.

## 5. After install

| Task | Command / URL |
| :--- | :--- |
| Check health | `curl https://pay-api.<ip>.sslip.io/health` |
| Admin login details | `sudo grep INITIAL_ADMIN /opt/youpi/.env` |
| Live logs | `journalctl -u youpi -f` |
| Restart | `sudo systemctl restart youpi` |
| Control Center (private) | `ssh -L 8090:127.0.0.1:8090 ubuntu@<ip>` → <http://localhost:8090> |
| Update to latest code | `sudo bash /opt/youpi/deploy/free-vm/setup.sh` (keeps `.env` and data) |
| Backup | `sudo tar czf youpi-backup.tgz -C /opt/youpi data .env` |

Then configure the gateway as usual (see [CONFIGURATION.md](CONFIGURATION.md), [OBSERVERS_SETUP.md](OBSERVERS_SETUP.md)):
receiving UPI ID in Merchant Admin, Android observer pointed at `https://pay-api.<ip>.sslip.io`, and Google OAuth
redirect URI `https://pay-gmail.<ip>.sslip.io/oauth/callback`.

## 6. Troubleshooting

| Symptom | Fix |
| :--- | :--- |
| URLs time out | Ingress rules for 80/443 missing in the Oracle Security List (§3.3) |
| Browser shows certificate error | Wait ~1 min on first visit; check `journalctl -u caddy -n 50` |
| `too many certificates` from Let's Encrypt | sslip.io shares rate limits — move to your own domain (§2) |
| Gateway not starting | `journalctl -u youpi -n 100` |
| 1 GB VM runs out of memory | `sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile && echo '/swapfile none swap sw 0 0' \| sudo tee -a /etc/fstab` |
| Oracle reclaims idle VM | Always Free instances idle < 20% CPU for 7 days may be reclaimed; upgrading the account to Pay-As-You-Go (still ₹0 within free limits) prevents this |
