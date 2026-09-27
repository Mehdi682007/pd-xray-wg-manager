# PD - Xray WG Manager

[فارسی](#راهنمای-فارسی) | [English](#english-guide)

Interactive WireGuard → Xray/VLESS gateway manager. **Version 3.2.2**.

```text
  ____  ____           __  __                         __        ______
 |  _ \|  _ \          \ \/ /_ __ __ _ _   _          \ \      / / ___|
 | |_) | | | |  _____   \  /| '__/ _` | | | |  _____   \ \ /\ / / |  _
 |  __/| |_| | |_____|  /  \| | | (_| | |_| | |_____|   \ V  V /| |_| |
 |_|   |____/          /_/\_\_|  \__,_|\__, |            \_/\_/  \____|
                                       |___/
```

## راهنمای فارسی

کاربر فقط برنامه WireGuard را روی گوشی یا کامپیوتر نصب می‌کند. این اسکریپت روی سرور، ترافیک TCP کاربران را از Xray و یک اتصال VLESS عبور می‌دهد. DNS با Unbound و TLS معتبر از همان مسیر عبور می‌کند.

### پیش‌نیازها

- دسترسی root، systemd و apt؛ محیط هدف Ubuntu 24.04 است. Debian و سایر نسخه‌های Ubuntu بررسی خانواده سیستم‌عامل را می‌گذرانند، ولی نصب تازه روی همه انتشارها آزمایش نشده است.
- پشتیبانی کرنل/محیط مجازی از WireGuard، nftables و network namespace.
- لینک VLESS قابل‌دسترسی از سرور و دسترسی دانلود بسته‌ها از مخازن سیستم‌عامل و GitHub.
- بازبودن UDP پورت WireGuard، پیش‌فرض `51820`، در فایروال ارائه‌دهنده و سیستم‌عامل.
- این نسخه از `wg0` و شبکه `10.66.66.0/24` استفاده می‌کند؛ تنظیم موجود ناسازگار را خودکار بازنویسی نمی‌کند.

### دانلود و اجرا

روی سرور اجرا کنید. اگر curl نصب نیست، ابتدا `sudo apt-get update && sudo apt-get install -y curl` را اجرا کنید.

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/Mehdi682007/pd-xray-wg-manager/main/pd-xray-wg-manager.sh -o pd-xray-wg-manager.sh && sudo bash pd-xray-wg-manager.sh
```

یا با wget:

```bash
wget -O pd-xray-wg-manager.sh https://raw.githubusercontent.com/Mehdi682007/pd-xray-wg-manager/main/pd-xray-wg-manager.sh
sudo bash pd-xray-wg-manager.sh
```

فایل را روی دیسک نگه دارید؛ rollback به مسیر فایل اسکریپت نیاز دارد. اجرای مستقیم با `bash <(curl ...)` برای این اسکریپت مناسب نیست.

### ترتیب استفاده

1. گزینه **۱: Quick setup** را اجرا و لینک VLESS را وارد کنید. نصب Unbound و وابستگی‌ها، Xray، WireGuard، DNS، routing و تست سلامت انجام می‌شود. **در این گزینه کلاینت ساخته نمی‌شود.**
2. گزینه **۶** را برای ساخت کلاینت بزنید؛ نام، IP عمومی سرور WireGuard، سقف حجم و اعتبار را وارد کنید. IP خروجی VLESS را به‌عنوان آدرس سرور وارد نکنید.
3. حجم `25` یعنی مجموع ۲۵ گیگابایت آپلود و دانلود. اعتبار `30` یا `+30` یعنی ۳۰ روز. مقدار صفر یعنی نامحدود/بدون انقضا. تاریخ میلادی کامل مانند `2026-12-31` تا پایان همان روز UTC معتبر است.
4. کانفیگ و QR نمایش داده می‌شوند. در WireGuard گوشی گزینه افزودن تونل و اسکن QR، یا واردکردن فایل را انتخاب کنید.
5. گزینه **۷** فهرست و مصرف، **۱۴** تغییر محدودیت/تمدید، و **۱۵** نمایش مجدد کانفیگ و QR است. خروج با **۰** انجام می‌شود.

نام تکراری در گزینه ۶ کانفیگ موجود را نشان می‌دهد و کلیدها را عوض نمی‌کند. فایل‌ها برای کلاینت `ali`:

```text
/etc/xray-gateway-manager/clients/ali.conf
/etc/xray-gateway-manager/clients/ali.png
```

فایل `.conf` یا PNG را با SFTP/WinSCP دریافت و فقط به همان کاربر تحویل دهید؛ هر دو حاوی اطلاعات خصوصی اتصال‌اند.

### امکانات و محدودیت‌ها

- نصب خودکار Unbound، WireGuard، Xray و ابزارهای لازم؛ انتخاب DNS سالم با آزمایش واقعی TLS از داخل VLESS.
- پشتیبانی URLهای VLESS با TLS، Reality یا none و transportهای TCP، WS و gRPC در محدوده parser؛ پارامتر ناشناخته رد می‌شود. WS/gRPC در نسخه Xray آزمایش‌شده هشدار deprecated دارند.
- حجم مجموع RX+TX بر مبنای WireGuard، هر GB برابر یک میلیارد بایت؛ ثبت روی دیسک و کنترل تقریباً هر ۱۵ ثانیه. ممکن است از سقف کمی عبور شود؛ در خاموشی ناگهانی آخرین مصرف ثبت‌نشده ممکن است از دست برود. مناسب صورتحساب دقیق تجاری نیست.
- `keep` مصرف قبلی را حفظ و `reset` شمارنده را صفر می‌کند؛ تمدید خودکار ماهانه وجود ندارد. برای بازشدن دسترسی باید هم شرط تاریخ و هم حجم اجازه دهند. handshake ممکن است برای کلاینت مسدود همچنان دیده شود.
- TCP و DNS پشتیبانی می‌شوند؛ **UDP غیر DNS و ICMP عبوری مسدودند**. برخی بازی‌ها، تماس‌ها و ping کار نمی‌کنند. UDP/443 رد می‌شود تا برنامه‌های پشتیبان به TCP برگردند.
- IPv6 اینترنت سرویس داده نمی‌شود؛ کانفیگ جدید `::/0` را نیز وارد تونل می‌کند تا مسیر معمول IPv6 خارج از تونل استفاده نشود. رفتار نهایی دستگاه باید بررسی شود.
- backup پیش از تغییر، rollback زمان‌دار، قوانین مستقل nftables و راه‌اندازی با systemd. backup جایگزین snapshot کامل سیستم یا نسخه‌های بسته‌ها نیست.
- تنظیمات firewall دیگری پاک نمی‌شوند؛ اگر UFW یا firewall پنل ترافیک را مسدود کند، باید قوانین آن با gateway سازگار شود.

### سلامت، لاگ و بازیابی

```bash
sudo bash pd-xray-wg-manager.sh test
sudo bash pd-xray-wg-manager.sh e2e
sudo bash pd-xray-wg-manager.sh client-show ali
sudo bash pd-xray-wg-manager.sh limits list
sudo bash pd-xray-wg-manager.sh limits set ali 25 30 reset
sudo bash pd-xray-wg-manager.sh backup
```

Backupها: `/var/backups/xray-gateway-manager/snapshot-*`؛ بازیابی با گزینه ۱۲ یا `restore SNAPSHOT_PATH`. بازیابی می‌تواند مصرف و محدودیت‌ها را هم به زمان snapshot برگرداند. گزینه ۱۳ integration را حذف و بسته‌ها، WireGuard، clientها و backupها را نگه می‌دارد؛ اینترنت gateway پس از حذف فراهم نمی‌شود.

خطاها پیش از rollback در `/var/log/xray-gateway-manager/failure-*.log` ذخیره می‌شوند. پیش از اشتراک، اطلاعات حساس احتمالی را بررسی کنید. برای خطای listener محلی، با تنظیم DNS حدس نزنید؛ وضعیت Xray و این لاگ را بررسی کنید.

نصب gateway و reboot روی یک Ubuntu 24.04 واقعی آزموده شده‌اند. اصلاحات بعدی با آزمون‌های هدفمند بررسی شده‌اند؛ **نصب تمیز آخرین نسخه روی تمام سیستم‌ها تأیید نشده است**. CI صحت syntax و چند regression مشخص را بررسی می‌کند، نه اتصال اینترنت یک VPS واقعی.

## English guide

Run a WireGuard server whose clients' IPv4 TCP traffic exits through an Xray VLESS outbound. Clients only need WireGuard. Unbound validates encrypted DNS through local Xray TCP relays and the same outbound.

### Requirements and installation

Target: **Ubuntu 24.04**, root, apt and systemd. Debian/other Ubuntu releases pass the family check but are not all clean-install tested. The kernel/container must support WireGuard, nftables and network namespaces. A working VLESS URL, package/GitHub access and an open WireGuard UDP port (default `51820`) are required. This version uses `wg0` and `10.66.66.0/24`.

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/Mehdi682007/pd-xray-wg-manager/main/pd-xray-wg-manager.sh -o pd-xray-wg-manager.sh && sudo bash pd-xray-wg-manager.sh
```

Download to a real file: rollback requires a persistent script path, so do not use process substitution (`bash <(curl ...)`). Install curl with apt first if needed. The wget commands above are an alternative.

### Setup and clients

1. Run **1 — Quick setup** and provide the VLESS URL. Dependencies (including Unbound), server configuration, encrypted DNS, routing and health tests are handled automatically. **Quick setup does not create a client.**
2. Use **6** to create a client. Enter the WireGuard server's public address, not the VLESS exit IP.
3. Enter a combined upload/download quota in decimal GB (`25` = 25 billion bytes), and days (`30` or `+30`) or a calendar expiry (`YYYY-MM-DD`, end of day UTC). `0` means unlimited/no expiry.
4. Scan the terminal QR in WireGuard, or import the generated `.conf` file.
5. **7** lists usage; **14** edits limits; **15** displays an existing config and creates its QR PNG. **0** exits. Reusing an existing name displays its config without rotating its key.

Client files are under `/etc/xray-gateway-manager/clients/NAME.conf` and `NAME.png`. Download via SFTP and share only with the intended client: both contain private connection material.

### Behavior and limits

- VLESS URL parsing supports TLS/Reality/none with TCP, WS and gRPC within the supported parameter set. Unknown parameters fail explicitly. The tested Xray version warns that WS/gRPC are deprecated.
- The installer tests authenticated DNS-over-TLS through VLESS and selects working upstreams. It does not silently fall back to insecure DNS.
- Quotas use WireGuard RX+TX, sampled approximately every 15 seconds and checkpointed to disk. Overshoot and loss of the last uncheckpointed sample after a crash are possible; this is not billing-grade accounting. `keep` preserves usage, `reset` starts a new usage period; there is no automatic monthly reset.
- Expired/over-quota clients have application traffic blocked. A WireGuard handshake can still appear. Renew both expiry and quota as needed; no client re-import is required.
- **Non-DNS forwarded UDP and ICMP are blocked.** Some games/calls and ping will not work. Rejecting UDP/443 lets compatible applications fall back to TCP.
- IPv6 Internet service is not provided. New client configs include `::/0` to capture normal native IPv6 traffic; verify behavior on the actual client device.
- Existing compatible WireGuard keys/peers are retained. Other firewalls are not erased; provider firewall/UFW rules may need to allow the required traffic.
- Backups and timed rollback cover manager settings, not the whole operating system or package versions. Restoring a snapshot can rewind usage/limits.

### Operations and troubleshooting

The commands in the Persian section also apply in English. `test` checks server services, DNS and proxy access. `e2e` creates and removes a temporary local WireGuard peer to test transparent HTTP/HTTPS and DNS; it does not test the mobile ISP path.

Backups: `/var/backups/xray-gateway-manager/snapshot-*`. Restore through option **12** or `sudo bash pd-xray-wg-manager.sh restore SNAPSHOT_PATH`. Option **13** removes integration while retaining packages, WireGuard/client files and backups; gateway service is no longer provided.

Pre-rollback diagnostics: `/var/log/xray-gateway-manager/failure-*.log`. Inspect for private information before sharing. Use `systemctl status xgw-limits.timer` and `journalctl -u xgw-limits.service` for quota monitoring issues.

The gateway/reboot path has been exercised on a real Ubuntu 24.04 server; subsequent fixes have targeted regression tests. **The latest release has not been clean-install verified on every supported environment.** CI validates syntax and selected regressions, not full VPS connectivity.
