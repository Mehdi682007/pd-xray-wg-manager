#!/usr/bin/env bash
# Ubuntu 24.04 / systemd. IPv4 TCP gateway; non-DNS UDP is deliberately blocked.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
VERSION=3.2.2
S=/etc/xray-gateway-manager
C=$S/clients
B=/var/backups/xray-gateway-manager
X=/usr/local/etc/xray/config.json
N=/etc/nftables.d/xray-gateway-manager.nft
U=/etc/unbound/unbound.conf.d/xray-gateway-manager.conf
XS=/etc/systemd/system/xray.service.d/20-gateway-manager.conf
US=/etc/systemd/system/unbound.service.d/xray-gateway-manager.conf
NS=/etc/systemd/system/xray-gateway-manager.service
WS=/etc/systemd/system/wg-quick@wg0.service.d/xray-gateway-manager.conf
TX=''
STAGE=initialization
log() { printf '[xgw] %s\n' "$*"; }
die() { log "$*" >&2; return 1; }
ask() { local a; read -r -p "$1 [$2]: " a; printf '%s' "${a:-$2}"; }
get() { [[ -f $S/state.env ]] && sed -n "s/^$1=//p" "$S/state.env" | head -1; }
put() { local t; t=$(mktemp "$S/.state.XXXX"); if [[ -f $S/state.env ]]; then sed "/^$1=/d" "$S/state.env" > "$t"; fi; printf '%s=%s\n' "$1" "$2" >> "$t"; mv "$t" "$S/state.env"; }
paths() {
 printf '%s\n' "$X" "$XS" "$N" "$U" "$US" "$NS" "$WS" /usr/local/libexec/xgw-apply /usr/local/libexec/xgw-limits.py /etc/systemd/system/xgw-limits.service /etc/systemd/system/xgw-limits.timer /etc/sysctl.d/99-xray-gateway-manager.conf /etc/wireguard/wg0.conf "$S"
}
backup() {
 local d p; d=$(mktemp -d "$B/snapshot-$(date +%Y%m%d-%H%M%S)-XXXX")
 mkdir -p "$d/files"
 paths > "$d/manifest"
 while read -r p; do [[ ! -e $p ]] || cp -a --parents "$p" "$d/files/"; done < "$d/manifest"
 for p in xray unbound wg-quick@wg0 xray-gateway-manager xgw-limits.timer; do
  printf '%s %s %s\n' "$p" "$(systemctl is-enabled "$p" 2>/dev/null || true)" "$(systemctl is-active "$p" 2>/dev/null || true)" >> "$d/services"
 done
 sysctl -n net.ipv4.ip_forward > "$d/forwarding"
 for p in /usr/local/etc/xray /var/log/xray /var/log/xray/access.log /var/log/xray/error.log; do
  [[ ! -e $p ]] || stat -c '%a %u %g %n' "$p" >> "$d/permissions"
 done
 nft list ruleset > "$d/rules-diagnostic.nft" 2>/dev/null || true
 : > "$d/owned-tables.nft"
 for p in 'ip xgw' 'inet xgw_filter'; do
  # Deliberate word splitting for two constant nft identifiers.
  IFS=' ' read -r family table <<< "$p"
  nft list table "$family" "$table" >> "$d/owned-tables.nft" 2>/dev/null || true
 done
 printf '%s\n' "$d"
}
restore_snapshot() {
 local d=$1 p unit enabled active mode uid gid
 [[ $(realpath "$d") == "$B"/snapshot-* && -f $d/manifest ]] || die 'Not a manager snapshot.'
 systemctl stop xgw-limits.timer xgw-limits.service 2>/dev/null || true
 systemctl stop xray-gateway-manager 2>/dev/null || true
 # Only fixed manager paths are restored; never execute a backup as shell code.
 while read -r p; do
  if [[ -e $d/files$p ]]; then
   [[ $p != "$S" ]] || rm -rf -- "$S"
   mkdir -p "$(dirname "$p")"; cp -a "$d/files$p" "$p"
  else
   [[ $p != "$S" ]] || continue
   rm -f -- "$p"
  fi
 done < <(paths)
 if [[ -f $d/permissions ]]; then
  while IFS=' ' read -r mode uid gid p; do
   case $p in /usr/local/etc/xray|/var/log/xray|/var/log/xray/access.log|/var/log/xray/error.log)
    [[ ! -e $p ]] || { chown "$uid:$gid" "$p"; chmod "$mode" "$p"; };;
   esac
  done < "$d/permissions"
 fi
 systemctl daemon-reload
 for unit in xray unbound wg-quick@wg0; do
  active=$(awk -v u="$unit" '$1==u {print $3}' "$d/services")
  if [[ $active == active ]]; then systemctl restart "$unit"; else systemctl stop "$unit" 2>/dev/null || true; fi
 done
 { printf 'table ip xgw\ndelete table ip xgw\ntable inet xgw_filter\ndelete table inet xgw_filter\n'; cat "$d/owned-tables.nft"; } > /run/xgw-restore.nft
 nft -f /run/xgw-restore.nft
 if [[ $(awk '$1=="xray-gateway-manager" {print $3}' "$d/services") == active ]]; then systemctl start xray-gateway-manager; fi
 while IFS=' ' read -r unit enabled active; do
  if [[ $enabled == enabled ]]; then systemctl enable "$unit" >/dev/null 2>&1 || true; else systemctl disable "$unit" >/dev/null 2>&1 || true; fi
 done < "$d/services"
 if [[ -f /usr/local/libexec/xgw-limits.py ]]; then
  python3 /usr/local/libexec/xgw-limits.py sync
  if [[ $(awk '$1=="xgw-limits.timer" {print $3}' "$d/services") == active ]]; then systemctl start xgw-limits.timer; fi
 else
  nft delete table inet xgw_limits 2>/dev/null || true
 fi
 sysctl -q -w "net.ipv4.ip_forward=$(cat "$d/forwarding")"
 log "Restored $d (packages and installed binaries are retained)."
}
failure() {
 local rc=$?
 trap - ERR
 log "Failed at line ${BASH_LINENO[0]} (exit $rc)." >&2
 diagnostics || true
 if [[ -n $TX ]]; then
  log "Restoring $TX" >&2
  restore_snapshot "$TX" || log "Automatic restore failed; snapshot: $TX" >&2
  systemctl stop xgw-manager-rollback.timer 2>/dev/null || true
 fi
 exit "$rc"
}
trap failure ERR
diagnostics() {
 local d
 d=/var/log/xray-gateway-manager
 mkdir -p "$d"; chmod 700 "$d"
 d=$(mktemp "$d/failure-$(date +%Y%m%d-%H%M%S)-XXXX.log")
 {
  printf 'Version=%s Stage=%s UTC=%s\n' "$VERSION" "$STAGE" "$(date -u +%FT%TZ)"
  uname -a
  for unit in xray unbound wg-quick@wg0 xray-gateway-manager; do
   systemctl show "$unit" -p ActiveState -p SubState -p Result -p ExecMainStatus -p User -p Group || true
   journalctl -u "$unit" -n 30 --no-pager || true
  done
  ss -lntup || true
  namei -l "$X" || true
  ip -br addr || true
  ip -4 route || true
 } > "$d" 2>&1
 log "Diagnostics saved BEFORE rollback: $d (root-only; inspect before sharing)." >&2
}
platform_check() {
 [[ -f /etc/os-release ]] || die 'Cannot identify operating system.'
 # os-release also defines VERSION; keep it local so it cannot replace ours.
 local ID='' VERSION_ID='' VERSION=''
 source /etc/os-release
 [[ $ID == ubuntu || $ID == debian ]] || die 'Supported family: Ubuntu/Debian with apt and systemd.'
 command -v apt-get >/dev/null || die 'apt-get is required.'
 if [[ $ID != ubuntu || $VERSION_ID != 24.04 ]]; then
  log "Detected $ID $VERSION_ID. Intended for Debian/Ubuntu; this release is not clean-install verified." >&2
 fi
}
wait_xray() {
 local attempt state
 STAGE=xray-readiness
 for attempt in {1..30}; do
  state=$(systemctl show xray -p ActiveState --value)
  if [[ $state == failed || $state == inactive ]]; then
   log "Xray stopped before becoming ready (state=$state)." >&2
   return 1
  fi
  # A Type=simple systemd start does not imply that sockets are ready.
  # Verify the SOCKS protocol, rather than only finding an open TCP port.
  if python3 - <<'PY'
import socket,sys
try:
 with socket.create_connection(('127.0.0.1',10808),timeout=1) as s:
  s.sendall(b'\x05\x01\x00')
  data=b''
  while len(data)<2:
   part=s.recv(2-len(data))
   if not part: raise OSError('closed')
   data+=part
  if data!=b'\x05\x00': raise OSError('not a no-auth SOCKS5 listener')
except Exception: sys.exit(1)
PY
  then return 0; fi
  sleep 1
 done
 log 'Xray did not provide a working SOCKS5 listener within the readiness deadline.' >&2
 return 1
}
start_xray() {
 STAGE=xray-config-validation
 # Validate with the actual service identity, not only root.
 runuser -u xraygw -- /usr/local/bin/xray run -test -format json -config "$X"
 systemctl reset-failed xray
 systemctl enable xray
 systemctl restart xray
 wait_xray
}
proxy_exit_ip() {
 local url result attempt
 STAGE=vless-connectivity
 for attempt in 1 2; do
  for url in https://api.ipify.org https://icanhazip.com; do
   if result=$(curl -4fsS --connect-timeout 5 --max-time 12 --socks5-hostname 127.0.0.1:10808 "$url" 2>/dev/null); then
    if python3 - "$result" <<'PY'
import ipaddress,sys
try: ipaddress.IPv4Address(sys.argv[1].strip())
except ValueError: sys.exit(1)
PY
    then printf '%s\n' "$result"; return 0; fi
   fi
  done
 done
 log 'Local SOCKS is ready, but HTTPS through VLESS failed against two test destinations. Check upstream reachability/credentials.' >&2
 return 1
}
select_dns_upstreams() {
 STAGE=dns-upstream-selection
 python3 - "$S/dns-upstreams.json" <<'PY'
import socket,ssl,struct,json,sys,os
def exact(s,n):
 data=b''
 while len(data)<n:
  part=s.recv(n-len(data))
  if not part: raise OSError('connection closed')
  data+=part
 return data
good=[]
ctx=ssl.create_default_context()
for ip,name in [('8.8.8.8','dns.google'),('8.8.4.4','dns.google'),('1.1.1.1','cloudflare-dns.com'),('1.0.0.1','cloudflare-dns.com'),('9.9.9.9','dns.quad9.net')]:
 try:
  with socket.create_connection(('127.0.0.1',10808),timeout=3) as s:
   s.settimeout(4)
   s.sendall(b'\x05\x01\x00')
   if exact(s,2)!=b'\x05\x00': raise OSError('SOCKS auth')
   s.sendall(b'\x05\x01\x00\x01'+socket.inet_aton(ip)+struct.pack('!H',853))
   head=exact(s,4)
   if head[1]!=0: raise OSError('SOCKS connect rejected')
   size={1:4,4:16}.get(head[3])
   if head[3]==3: size=exact(s,1)[0]
   if size is None: raise OSError('invalid SOCKS address')
   exact(s,size+2)
   with ctx.wrap_socket(s,server_hostname=name) as tls:
    ident=os.urandom(2)
    query=ident+bytes.fromhex('01000001000000000000')+b'\x07example\x03com\x00'+struct.pack('!HH',1,1)
    tls.sendall(struct.pack('!H',len(query))+query)
    reply=exact(tls,struct.unpack('!H',exact(tls,2))[0])
    if len(reply)<12 or reply[:2]!=ident or not reply[2]&128 or reply[3]&15 or struct.unpack('!H',reply[6:8])[0]<1:
     raise OSError('invalid DNS answer')
  good.append({'ip':ip,'name':name})
  print('[xgw] Validated encrypted DNS via VLESS: '+ip+' / '+name,flush=True)
  if len(good)==2: break
 except (OSError,ValueError) as exc:
  print('[xgw] DNS candidate unavailable: '+ip+' ('+type(exc).__name__+')',flush=True)
if not good: raise SystemExit('No authenticated DNS-over-TLS candidate worked through VLESS. No insecure fallback applied.')
if len(good)==1: good.append(good[0])
tmp=sys.argv[1]+'.new'
with open(tmp,'w') as f: json.dump(good,f)
os.chmod(tmp,0o600); os.replace(tmp,sys.argv[1])
PY
}
begin() {
 [[ -z $TX ]] || return 0
 TX=$(backup)
 log "Backup: $TX"
 # Use a private copy so rollback still works if the invoking script is moved.
 install -m 700 "$(realpath "$0")" /run/xgw-manager-rollback.sh
 systemctl stop xgw-manager-rollback.timer 2>/dev/null || true
 systemctl reset-failed xgw-manager-rollback.service 2>/dev/null || true
 systemd-run --quiet --unit=xgw-manager-rollback --on-active=10m /bin/bash /run/xgw-manager-rollback.sh restore-internal "$TX"
}
commit() { systemctl stop xgw-manager-rollback.timer; TX=''; }
requirements() {
 STAGE=package-installation
 log "Pre-install snapshot: $(backup)"
 export DEBIAN_FRONTEND=noninteractive
 apt-get update
 apt-get install -y --no-install-recommends ca-certificates curl jq nftables unbound unbound-anchor dns-root-data dnsutils wireguard-tools iproute2 qrencode python3 openssl util-linux
 # Do not enable/restart the distribution nftables unit: it may flush other tables.
 if [[ ! -x /usr/local/bin/xray ]]; then
  local t; t=$(mktemp)
  curl -fL --retry 3 --connect-timeout 15 --max-time 120 https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh -o "$t"
  bash "$t" install
  rm -f "$t"
 fi
}
ensure_requirements() {
 local cmd
 for cmd in unbound unbound-checkconf unbound-anchor dig wg wg-quick nft jq qrencode python3 curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then requirements; return; fi
 done
 [[ -x /usr/local/bin/xray ]] || requirements
}
parse_vless() {
 python3 - "$1" <<'PY'
import sys,json,urllib.parse,uuid,re
u=urllib.parse.urlsplit(sys.argv[1].strip())
if u.scheme!='vless' or not u.hostname or not u.username or not u.port or u.password:
 raise SystemExit('Expected vless://UUID@host:port?...')
if u.path not in ('','/'): raise SystemExit('Put transport path in the path query parameter.')
uid=str(uuid.UUID(urllib.parse.unquote(u.username)))
q=urllib.parse.parse_qs(u.query,keep_blank_values=True)
allowed={'type','security','encryption','flow','sni','fp','pbk','publicKey','sid','shortId','spx','spiderX','host','path','serviceName','service','alpn','headerType','mode','authority'}
bad=set(q)-allowed
if bad: raise SystemExit('Unsupported parameters: '+', '.join(sorted(bad)))
if any(len(v)!=1 for v in q.values()): raise SystemExit('Duplicate parameters are not supported.')
def one(k,d=''): return q.get(k,[d])[0] # parse_qs already percent-decodes once
for a,b in [('pbk','publicKey'),('sid','shortId'),('spx','spiderX'),('serviceName','service')]:
 if a in q and b in q: raise SystemExit('Use only one of '+a+' / '+b)
net=one('type','tcp'); sec=one('security','none'); flow=one('flow')
if net not in ('tcp','ws','grpc'): raise SystemExit('Supported transports: tcp, ws, grpc')
if sec not in ('tls','reality','none'): raise SystemExit('Supported security: tls, reality, none')
if one('encryption','none')!='none': raise SystemExit('Only encryption=none is supported.')
if flow and (flow!='xtls-rprx-vision' or net!='tcp' or sec not in ('tls','reality')):
 raise SystemExit('flow requires tcp + tls/reality and must be xtls-rprx-vision.')
if one('headerType','none')!='none': raise SystemExit('TCP header camouflage is unsupported.')
if sec!='reality' and set(q)&{'pbk','publicKey','sid','shortId','spx','spiderX'}: raise SystemExit('Reality parameters require security=reality.')
if sec=='none' and set(q)&{'sni','fp','alpn'}: raise SystemExit('TLS parameters require tls/reality.')
if net!='ws' and set(q)&{'host','path'}: raise SystemExit('host/path are supported only for ws.')
if net!='grpc' and set(q)&{'serviceName','service','mode','authority'}: raise SystemExit('gRPC parameters require type=grpc.')
if net!='tcp' and 'headerType' in q: raise SystemExit('headerType is TCP-only.')
st={'network':net,'security':sec}
if sec=='tls':
 st['tlsSettings']={'serverName':one('sni',u.hostname),'fingerprint':one('fp','chrome'),'allowInsecure':False}
 if one('alpn'): st['tlsSettings']['alpn']=one('alpn').split(',')
if sec=='reality':
 if 'alpn' in q: raise SystemExit('alpn is unsupported with Reality in this installer.')
 pb=one('pbk') or one('publicKey'); sid=one('sid') or one('shortId')
 if not re.fullmatch(r'[A-Za-z0-9_-]{43}',pb): raise SystemExit('Reality requires a 43-character pbk.')
 if not re.fullmatch(r'(?:[0-9a-fA-F]{2}){0,8}',sid): raise SystemExit('sid must be even-length hex, at most 16 characters.')
 st['realitySettings']={'serverName':one('sni',u.hostname),'fingerprint':one('fp','chrome'),'publicKey':pb,'shortId':sid,'spiderX':one('spx') or one('spiderX','/')}
if net=='ws':
 st['wsSettings']={'path':one('path','/')}
 if one('host'): st['wsSettings']['host']=one('host')
if net=='grpc':
 if one('mode','gun') not in ('gun','multi'): raise SystemExit('gRPC mode must be gun or multi.')
 st['grpcSettings']={'serviceName':one('serviceName') or one('service'),'multiMode':one('mode','gun')=='multi'}
 if one('authority'): st['grpcSettings']['authority']=one('authority')
user={'id':uid,'encryption':'none'}
if flow: user['flow']=flow
print(json.dumps({'tag':'proxy','protocol':'vless','settings':{'vnext':[{'address':u.hostname,'port':u.port,'users':[user]}]},'streamSettings':st}))
PY
}
xray_permissions() {
 id xraygw >/dev/null 2>&1 || useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin xraygw
 mkdir -p "$(dirname "$XS")" /var/log/xray
 chown root:xraygw "$X"; chmod 640 "$X"
 chmod o+x /usr/local/etc /usr/local/etc/xray
 chown xraygw:xraygw /var/log/xray
 for f in /var/log/xray/access.log /var/log/xray/error.log; do [[ ! -f $f ]] || chown xraygw:xraygw "$f"; done
 cat > "$XS" <<'EOF'
[Service]
User=xraygw
Group=xraygw
EOF
}
configure_proxy() {
 ensure_requirements
 local url out t
 read -r -s -p 'VLESS URL (hidden): ' url; echo
 out=$(parse_vless "$url"); unset url
 begin
 mkdir -p "$(dirname "$X")"
 t=$(mktemp "$(dirname "$X")/.candidate.XXXX")
 jq -n --argjson o "$out" '{log:{loglevel:"warning"},inbounds:[],outbounds:[$o],routing:{domainStrategy:"AsIs",rules:[]}}' > "$t"
 /usr/local/bin/xray run -test -format json -config "$t"
 mv "$t" "$X"
 if [[ -f $N ]]; then add_inbounds gateway; else add_inbounds local; fi
 xray_permissions
 systemctl daemon-reload
 start_xray
 proxy_exit_ip
 put XRAY_READY 1
 commit
}
add_inbounds() {
 python3 - "$X" "${1:-local}" "$S/dns-upstreams.json" <<'PY'
import json,sys,os
p=sys.argv[1]; c=json.load(open(p))
if not any(o.get('tag')=='proxy' and o.get('protocol')=='vless' for o in c.get('outbounds',[])):
 raise SystemExit('Existing config requires a VLESS outbound tagged proxy; use option 3.')
tags=['transparent-in','socks-in','http-in','dns-dot-google','dns-dot-google2']
c['inbounds']=[i for i in c.get('inbounds',[]) if i.get('tag') not in tags]
c['inbounds'] += [
 {'tag':'transparent-in','listen':'0.0.0.0' if sys.argv[2]=='gateway' else '127.0.0.1','port':12345,'protocol':'dokodemo-door','settings':{'network':'tcp','followRedirect':True}},
 {'tag':'socks-in','listen':'127.0.0.1','port':10808,'protocol':'socks','settings':{'auth':'noauth','udp':False}},
 {'tag':'http-in','listen':'127.0.0.1','port':10809,'protocol':'http','settings':{}}]
dns=json.load(open(sys.argv[3])) if os.path.exists(sys.argv[3]) else [{'ip':'8.8.8.8'},{'ip':'8.8.4.4'}]
for tag,port,addr in [('dns-dot-google',1053,dns[0]['ip']),('dns-dot-google2',1054,dns[1]['ip'])]:
 c['inbounds'].append({'tag':tag,'listen':'127.0.0.1','port':port,'protocol':'dokodemo-door','settings':{'address':addr,'port':853,'network':'tcp'}})
r=c.setdefault('routing',{}); old=[]
for rule in r.get('rules',[]):
 if set(rule.get('inboundTag',[]))&set(tags):
  rule['inboundTag']=[t for t in rule['inboundTag'] if t not in tags]
  if not rule['inboundTag']: continue
 old.append(rule)
r['rules']=[{'type':'field','inboundTag':tags,'outboundTag':'proxy'}]+old
t=p+'.new'; json.dump(c,open(t,'w'),indent=2); os.chmod(t,0o600)
PY
 /usr/local/bin/xray run -test -format json -config "$X.new"
 mv "$X.new" "$X"
}
configure_wg() {
 ensure_requirements
 STAGE=wireguard-configuration
 local port priv
 begin
 mkdir -p /etc/wireguard
 chmod 700 /etc/wireguard
 if [[ -f /etc/wireguard/wg0.conf ]]; then
  log 'Keeping existing wg0 keys and peers.'
  grep -Eq '^Address[[:space:]]*=[[:space:]]*10\.66\.66\.1/24[[:space:]]*$' /etc/wireguard/wg0.conf || die 'This installer requires wg0 = 10.66.66.1/24; existing config retained.'
  if grep -Eiq '^SaveConfig[[:space:]]*=[[:space:]]*true' /etc/wireguard/wg0.conf; then die 'SaveConfig=true is incompatible with persistent peer editing; config retained.'; fi
 else
  port=$(ask 'WireGuard UDP port' 51820)
  [[ $port =~ ^[0-9]+$ && ${#port} -le 5 ]] && ((10#$port >= 1 && 10#$port <= 65535)) || die 'Invalid port.'
  priv=$(wg genkey)
  printf '[Interface]\nAddress = 10.66.66.1/24\nListenPort = %s\nPrivateKey = %s\nSaveConfig = false\n' "$port" "$priv" > /etc/wireguard/wg0.conf
 fi
 printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-xray-gateway-manager.conf
 sysctl -q -w net.ipv4.ip_forward=1
 systemctl enable --now wg-quick@wg0
 [[ $(ip -4 -o addr show wg0 | awk '{print $4}') == 10.66.66.1/24 ]] || die 'Unexpected wg0 live address.'
 put WG_IF wg0; put WG_PORT "$(wg show wg0 listen-port)"
 put WG_GATEWAY 10.66.66.1; put WG_NETWORK 10.66.66.0/24
 put WG_SERVER_CIDR 10.66.66.1/24
 put WG_SERVER_PUBLIC_KEY "$(wg show wg0 public-key)"
 commit
}
write_routing() {
 mkdir -p /etc/nftables.d /usr/local/libexec "$(dirname "$WS")" "$(dirname "$US")"
 cat > "$N" <<'EOF'
table ip xgw
delete table ip xgw
table inet xgw_filter
delete table inet xgw_filter
table ip xgw {
 chain prerouting {
  type nat hook prerouting priority dstnat; policy accept;
  iifname "wg0" udp dport 53 counter dnat to 10.66.66.1:53
  iifname "wg0" tcp dport 53 counter dnat to 10.66.66.1:53
  iifname "wg0" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return
  iifname "wg0" meta l4proto tcp counter redirect to :12345
 }
}
table inet xgw_filter {
 chain input {
  type filter hook input priority -10; policy accept;
  iifname != "wg0" iifname != "lo" tcp dport { 12345, 1053, 1054 } counter reject with tcp reset
 }
 chain forward {
  type filter hook forward priority -10; policy accept;
  iifname "wg0" udp dport 443 counter reject with icmpx type port-unreachable
  iifname "wg0" counter reject with icmpx type admin-prohibited
 }
}
EOF
 # A single nft batch replaces only our two tables atomically. No flush ruleset.
 cat > /usr/local/libexec/xgw-apply <<'EOF'
#!/bin/sh
set -eu
/usr/sbin/nft -c -f /etc/nftables.d/xray-gateway-manager.nft
exec /usr/sbin/nft -f /etc/nftables.d/xray-gateway-manager.nft
EOF
 chmod 755 /usr/local/libexec/xgw-apply
 cat > "$NS" <<'EOF'
[Unit]
Description=Xray WireGuard gateway rules
After=network.target nftables.service
Before=wg-quick@wg0.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/libexec/xgw-apply
ExecReload=/usr/local/libexec/xgw-apply
# Rules deliberately remain installed on stop to prevent direct leakage.
[Install]
WantedBy=multi-user.target
EOF
 cat > "$WS" <<'EOF'
[Unit]
Requires=xray-gateway-manager.service
After=xray-gateway-manager.service
EOF
 cat > "$US" <<'EOF'
[Unit]
# ip-freebind lets Unbound start before wg0 exists. Do not order after
# WireGuard or Xray: both are After=nss-lookup while Unbound is Before it.
EOF
 cat > "$U" <<'EOF'
server:
    interface: 10.66.66.1
    ip-freebind: yes
    access-control: 10.66.66.0/24 allow
    access-control: 127.0.0.0/8 allow
    do-ip4: yes
    do-ip6: no
    do-not-query-localhost: no
    hide-identity: yes
    hide-version: yes
    tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"
    prefetch: yes
    edns-buffer-size: 1232
forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-first: no
    forward-addr: 127.0.0.1@1053#dns.google
    forward-addr: 127.0.0.1@1054#dns.google
EOF
 if [[ -f $S/dns-upstreams.json ]]; then
  python3 - "$U" "$S/dns-upstreams.json" <<'PY'
import json,sys
p=sys.argv[1]; dns=json.load(open(sys.argv[2])); text=open(p).read()
text=text.replace('127.0.0.1@1053#dns.google','127.0.0.1@1053#'+dns[0]['name'])
text=text.replace('127.0.0.1@1054#dns.google','127.0.0.1@1054#'+dns[1]['name'])
open(p,'w').write(text)
PY
 fi
 unbound-checkconf
 nft -c -f "$N"
}
configure_routing() {
 ensure_requirements
 STAGE=routing-configuration
 [[ -f $X && -f /etc/wireguard/wg0.conf ]] || die 'Configure Xray and WireGuard first.'
 wg show wg0 >/dev/null
 begin
 # Preserve the first pre-integration Xray configuration for uninstall.
 if [[ ! -f $S/pre-integration-xray.json ]]; then cp -a "$X" "$S/pre-integration-xray.json"; fi
 wait_xray
 select_dns_upstreams
 add_inbounds gateway
 xray_permissions
 write_routing
 systemctl daemon-reload
 systemctl enable xray unbound wg-quick@wg0 xray-gateway-manager
 systemctl restart xray-gateway-manager
 start_xray
 systemctl restart unbound
 install_limits
 put ROUTING_MODE wireguard
 put UDP_POLICY block
 health
 e2e
 commit
 log 'TCP through VLESS; encrypted DNS through VLESS; other forwarded traffic blocked.'
}
install_limits() {
 mkdir -p /usr/local/libexec
 cat > /usr/local/libexec/xgw-limits.py <<'LIMITS_PY'
#!/usr/bin/env python3
"""WireGuard RX+TX polling quotas. Poll every 15s; not billing-grade metering."""
import datetime as dt
import decimal
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess as sp
import sys
import tempfile
import time

ROOT = Path('/etc/xray-gateway-manager')
DB = ROOT / 'limits.json'

def run(args, data=None):
    return sp.run(args, input=data, text=True, capture_output=True, check=True).stdout

def delta(current, previous, same_generation):
    return current - previous if same_generation and current >= previous else current

def parse_limit(gb, expiry, now):
    value = decimal.Decimal(gb)
    if not value.is_finite() or value < 0 or value > 1000000:
        raise ValueError('Traffic must be 0..1000000 GB; 0 means unlimited.')
    quota = int(value * 1_000_000_000)
    if value > 0 and quota == 0:
        raise ValueError('Minimum quota is one byte.')
    if expiry == '0':
        until = 0
    elif re.fullmatch(r'\+?[1-9][0-9]{0,4}', expiry):
        until = now + int(expiry.lstrip('+')) * 86400
    else:
        # Calendar dates expire at the start of the following UTC day.
        day = dt.date.fromisoformat(expiry)
        until = int(dt.datetime.combine(day + dt.timedelta(days=1), dt.time(), dt.timezone.utc).timestamp())
    return quota, until

def reason(row, now):
    if row['expires'] and now >= row['expires']:
        return 'EXPIRED'
    if row['quota'] and row['used'] >= row['quota']:
        return 'QUOTA'
    return 'ACTIVE'

def discover():
    result = {}
    # Only the named peers created by this manager are managed.
    server = Path('/etc/wireguard/wg0.conf').read_text()
    for match in re.finditer(r'(?m)^# xgw-client:([a-zA-Z0-9_-]{1,40})\s*\n\[Peer\]\n(.*?)(?=^# xgw-client:|^\[|\Z)', server, re.S | re.M):
        name, body = match.groups()
        public = re.search(r'(?m)^PublicKey\s*=\s*(\S+)', body)
        allowed = re.search(r'(?m)^AllowedIPs\s*=\s*([^\n]+)', body)
        if not public or not allowed:
            raise ValueError('Malformed managed peer: ' + name)
        addr = ipaddress.ip_interface(allowed[1].strip())
        if addr.version != 4 or addr.network.prefixlen != 32:
            raise ValueError('Managed peers require one IPv4 /32: ' + name)
        if name in result:
            raise ValueError('Duplicate client name: ' + name)
        result[name] = (public[1], str(addr.ip))
    return result

def save(db):
    fd, tmp = tempfile.mkstemp(prefix='.limits-', dir=ROOT)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(db, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, DB)
        fd = os.open(ROOT, os.O_DIRECTORY)
        try: os.fsync(fd)
        finally: os.close(fd)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def enforce(blocked):
    elements = ', '.join(sorted(blocked))
    # Separate table: manager routing reload cannot reset expiry enforcement.
    rules = '''table inet xgw_limits
delete table inet xgw_limits
table inet xgw_limits {
 set blocked { type ipv4_addr; %s }
 chain input { type filter hook input priority -30; policy accept;
  iifname "wg0" ip saddr @blocked counter drop
 }
 chain output { type filter hook output priority -30; policy accept;
  oifname "wg0" ip daddr @blocked counter drop
 }
 chain forward { type filter hook forward priority -30; policy accept;
  iifname "wg0" ip saddr @blocked counter drop
  oifname "wg0" ip daddr @blocked counter drop
 }
}
''' % ('elements = { ' + elements + ' }' if elements else '')
    run(['nft', '-f', '-'], rules)

def main(argv):
    action = argv[0] if argv else 'sync'
    if action not in ('sync', 'list', 'set'):
        raise ValueError('Usage: sync | list | set NAME GB EXPIRY [reset|keep]')
    now = int(time.time())
    settings = None
    if action == 'set':
        if len(argv) not in (4, 5) or (len(argv) == 5 and argv[4] not in ('reset', 'keep')):
            raise ValueError('Usage: set NAME GB YYYY-MM-DD|+DAYS|0 [reset|keep]')
        settings = parse_limit(argv[2], argv[3], now)
    ROOT.mkdir(mode=0o700, exist_ok=True)
    with open('/run/xgw-limits.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        db = json.loads(DB.read_text()) if DB.exists() else {'version': 1, 'clients': {}}
        if db.get('version') != 1: raise ValueError('Unsupported limits database version')
        peers = discover()
        if action == 'set' and argv[1] not in peers: raise ValueError('Unknown managed client: ' + argv[1])
        live = {}
        if Path('/sys/class/net/wg0/ifindex').exists():
            generation = Path('/proc/sys/kernel/random/boot_id').read_text().strip() + ':' + Path('/sys/class/net/wg0/ifindex').read_text().strip()
            for line in run(['wg', 'show', 'wg0', 'transfer']).splitlines():
                public, rx, tx = line.split()
                live[public] = (int(rx), int(tx))
        else:
            generation = None
        # Remove records for peers explicitly removed from the persistent config.
        db['clients'] = {k: v for k, v in db['clients'].items() if k in peers}
        for name, (public, ip) in peers.items():
            row = db['clients'].get(name)
            current = live.get(public)
            if row is None or row.get('public') != public:
                row = {'public': public, 'quota': 0, 'expires': 0, 'used': 0,
                       'rx': current[0] if current else 0, 'tx': current[1] if current else 0,
                       'generation': generation, 'created': now}
                db['clients'][name] = row
            elif current is not None:
                same = generation == row.get('generation')
                row['used'] += delta(current[0], row['rx'], same) + delta(current[1], row['tx'], same)
                row['rx'], row['tx'] = current
                row['generation'] = generation
            elif generation is not None:
                # A peer removed and recreated during this boot starts at zero.
                row['rx'] = row['tx'] = 0
            row['ip'] = ip
        if settings is not None:
            row = db['clients'][argv[1]]
            row['quota'], row['expires'] = settings
            if len(argv) == 5 and argv[4] == 'reset': row['used'] = 0
        db['updated'] = now
        # Save the accounting checkpoint before enforcing. Boot reapplies it.
        save(db)
        enforce({r['ip'] for r in db['clients'].values() if reason(r, now) != 'ACTIVE'})
        if action in ('list', 'set'):
            print('NAME\tUSED_GB\tLIMIT_GB\tEXPIRES_UTC\tSTATUS')
            for name, row in sorted(db['clients'].items()):
                date = dt.datetime.fromtimestamp(row['expires'], dt.timezone.utc).isoformat() if row['expires'] else 'never'
                print(f"{name}\t{row['used']/1e9:.6f}\t{row['quota']/1e9 if row['quota'] else 'unlimited'}\t{date}\t{reason(row,now)}")

if __name__ == '__main__':
    try: main(sys.argv[1:])
    except Exception as exc:
        print('xgw-limits: ' + str(exc), file=sys.stderr)
        sys.exit(1)
LIMITS_PY
 chmod 700 /usr/local/libexec/xgw-limits.py
 cat > /etc/systemd/system/xgw-limits.service <<'EOF'
[Unit]
Description=WireGuard client traffic and expiry enforcement
After=local-fs.target nftables.service
Before=wg-quick@wg0.service
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/libexec/xgw-limits.py sync
EOF
 cat > /etc/systemd/system/xgw-limits.timer <<'EOF'
[Unit]
Description=Check WireGuard client limits every 15 seconds
[Timer]
OnBootSec=5s
OnUnitActiveSec=15s
AccuracySec=1s
Unit=xgw-limits.service
[Install]
WantedBy=timers.target
EOF
 # Ensure limits are loaded before peers can forward traffic after boot.
 if [[ -f $WS ]] && ! grep -q '^Requires=xgw-limits.service' "$WS"; then
  printf '\nRequires=xgw-limits.service\nAfter=xgw-limits.service\n' >> "$WS"
 fi
 systemctl daemon-reload
 python3 /usr/local/libexec/xgw-limits.py sync
 systemctl enable --now xgw-limits.timer
}
limit_settings() {
 local gb expiry reset
 while true; do
  gb=$(ask 'Total upload + download limit in GB (0 = unlimited)' 0) || return 1
  if python3 - "$gb" <<'PY'
from decimal import Decimal,InvalidOperation
import sys
try:
 v=Decimal(sys.argv[1])
 if not v.is_finite() or v<0 or v>1000000 or (v>0 and int(v*1000000000)==0): raise ValueError()
except (ValueError,InvalidOperation):
 raise SystemExit('Invalid volume. Enter a number such as 25 or 0 for unlimited.')
PY
  then break; fi
 done
 while true; do
  expiry=$(ask 'Validity in days (e.g. 30), YYYY-MM-DD UTC, or 0 = never' 0) || return 1
  if python3 - "$expiry" <<'PY'
import datetime,re,sys
s=sys.argv[1]
if s=='0' or re.fullmatch(r'\+?[1-9][0-9]{0,4}',s): sys.exit(0)
try:
 if not re.fullmatch(r'\d{4}-\d{2}-\d{2}',s): raise ValueError()
 d=datetime.date.fromisoformat(s)
 datetime.datetime.combine(d+datetime.timedelta(days=1),datetime.time(),datetime.timezone.utc).timestamp()
except (ValueError,OverflowError):
 raise SystemExit('Invalid validity. Use 30 (days), +30, 2026-12-31, or 0.')
PY
  then break; fi
 done
 while true; do
  reset=$(ask 'Usage counter: keep or reset' keep) || return 1
  [[ $reset == keep || $reset == reset ]] && break
  printf 'Enter keep or reset.\n' >&2
 done
 printf '%s\t%s\t%s\n' "$gb" "$expiry" "$reset"
}
limits_menu() {
 local name settings gb expiry reset
 clients_list
 read -r -p 'Client name to edit limits (blank = back): ' name
 [[ -n $name ]] || return 0
 if [[ ! $name =~ ^[a-zA-Z0-9_-]{1,40}$ || ! -f $C/$name.conf ]]; then
  log 'Unknown saved client.'; return 0
 fi
 settings=$(limit_settings)
 IFS=$'\t' read -r gb expiry reset <<< "$settings"
 begin
 install_limits
 python3 /usr/local/libexec/xgw-limits.py set "$name" "$gb" "$expiry" "$reset"
 commit
}
client_create() {
 ensure_requirements
 local name endpoint cip priv pub psk t settings gb expiry reset
 [[ -f $N ]] || die 'Configure routing first.'
 name=$(ask 'Client name' phone)
 if [[ ! $name =~ ^[a-zA-Z0-9_-]{1,40}$ ]]; then
  log 'Invalid name. Use 1-40 letters, numbers, underscore or hyphen.'; return 0
 fi
 if [[ -f $C/$name.conf ]]; then
  log 'This name already has a saved config. Showing it without changing keys or limits.'
  client_show "$name"; return 0
 fi
 endpoint=$(ask 'Server public IPv4 or DNS name (not proxy exit IP)' "$(get ENDPOINT || true)")
 python3 - "$endpoint" <<'PY'
import re,sys
s=sys.argv[1]
if len(s)>253 or not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?',s): raise SystemExit('Invalid endpoint.')
PY
 # Ask and validate every limit BEFORE creating keys, files or a live peer.
 settings=$(limit_settings)
 IFS=$'\t' read -r gb expiry reset <<< "$settings"
 begin
 cip=$(python3 - <<'PY'
import ipaddress,re,subprocess
s=open('/etc/wireguard/wg0.conf').read()+'\n'+subprocess.check_output(['wg','show','wg0','allowed-ips'],text=True)
used=[ipaddress.ip_network(x,strict=False) for x in re.findall(r'\b(?:\d{1,3}\.){3}\d{1,3}/\d{1,2}',s) if x!='10.66.66.1/24']
for i in range(2,255):
 ip=ipaddress.ip_address('10.66.66.'+str(i))
 if not any(ip in n for n in used): print(ip); break
else: raise SystemExit('No free addresses.')
PY
 )
 priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey); psk=$(wg genpsk)
 cat >> /etc/wireguard/wg0.conf <<EOF

# xgw-client:$name
[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = $cip/32
EOF
 t=$(mktemp); wg-quick strip wg0 > "$t"; wg syncconf wg0 "$t"; rm -f "$t"
 cat > "$C/$name.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = $cip/32
DNS = 10.66.66.1
MTU = 1380

[Peer]
PublicKey = $(wg show wg0 public-key)
PresharedKey = $psk
Endpoint = $endpoint:$(wg show wg0 listen-port)
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
 # ::/0 captures IPv6 on the client; this IPv4-only gateway intentionally does
 # not serve IPv6. Prevents normal native IPv6 bypass on supported clients.
 printf '%s\n' "$pub" > "$C/$name.pub"
 put ENDPOINT "$endpoint"
 install_limits
 python3 /usr/local/libexec/xgw-limits.py set "$name" "$gb" "$expiry" "$reset"
 commit
 client_show "$name"
}
clients_list() {
 local f count=0
 for f in "$C"/*.conf; do [[ ! -f $f ]] || count=$((count+1)); done
 if (( count == 0 )); then
  log 'No saved clients. Use option 6 to create a client and its configuration/QR.'
 fi
 if [[ -f /usr/local/libexec/xgw-limits.py ]]; then python3 /usr/local/libexec/xgw-limits.py list; fi
 for f in "$C"/*.conf; do
  [[ -f $f ]] || continue
  printf '%s: ' "$(basename "$f" .conf)"; sed -n 's/^Address = //p' "$f"
  printf '  Config: %s\n' "$f"
 done
 if wg show wg0 >/dev/null 2>&1; then wg show wg0; else log 'wg0 is not running.'; fi
}
client_show() {
 local name=${1:-} file
 if [[ -z $name ]]; then
  clients_list
  read -r -p 'Client name to show/export (blank = back): ' name
  [[ -n $name ]] || return 0
 fi
 if [[ ! $name =~ ^[a-zA-Z0-9_-]{1,40}$ || ! -f $C/$name.conf ]]; then
  log 'No saved configuration for this client. Use option 6 to create one.'
  return 0
 fi
 file="$C/$name.conf"
 log "Client configuration: $file"
 printf '\n'; cat "$file"; printf '\n'
 if command -v qrencode >/dev/null 2>&1; then
  if ! qrencode -t ANSIUTF8 < "$file"; then
   log 'Terminal QR rendering failed; the client is saved. Import the .conf file.'
  fi
  if qrencode -t PNG -o "$C/$name.png" < "$file"; then
   chmod 600 "$C/$name.png"
   log "QR image: $C/$name.png"
  else
   log 'PNG generation failed; the client is saved. Import the .conf file.'
  fi
 else
  log 'qrencode is missing. Option 2 installs it; the .conf can already be imported.'
 fi
 log 'The config and QR contain the client private key. Share only with its intended user.'
}
client_remove() {
 local name pub t
 clients_list
 read -r -p 'Client name to revoke: ' name
 [[ $name =~ ^[a-zA-Z0-9_-]{1,40}$ && -f $C/$name.conf ]] || die 'Unknown managed client.'
 begin
 pub=$(python3 - "$name" <<'PY'
import re,sys
p='/etc/wireguard/wg0.conf'; s=open(p).read(); name=sys.argv[1]
pat=r'(?m)^# xgw-client:'+re.escape(name)+r'\s*\n\[Peer\]\n.*?(?=^# xgw-client:|^\[|\Z)'
m=re.search(pat,s,re.S|re.M)
if not m: raise SystemExit('Managed peer marker not found; no changes.')
key=re.search(r'(?m)^PublicKey\s*=\s*(\S+)',m[0])
if not key: raise SystemExit('Peer key not found.')
open(p,'w').write(s[:m.start()]+s[m.end():]); print(key[1])
PY
 )
 wg set wg0 peer "$pub" remove
 rm -f "$C/$name.conf" "$C/$name.pub" "$C/$name.png"
 if [[ -f /usr/local/libexec/xgw-limits.py ]]; then python3 /usr/local/libexec/xgw-limits.py sync; fi
 commit
 log "Revoked $name."
}
health() {
 local result
 for unit in xray unbound wg-quick@wg0 xray-gateway-manager; do systemctl is-active --quiet "$unit"; done
 wait_xray
 result=$(proxy_exit_ip)
 log "VLESS exit: $result"
 for mode in udp tcp; do
  if [[ $mode == tcp ]]; then result=$(dig @10.66.66.1 example.com +tcp +time=8 +tries=1); else result=$(dig @10.66.66.1 example.com +time=8 +tries=1); fi
  grep -q 'status: NOERROR' <<< "$result"
  grep -Eq 'ANSWER: [1-9]' <<< "$result"
  log "DNS $mode: PASS"
 done
 nft list table ip xgw >/dev/null
 nft list table inet xgw_filter >/dev/null
 log 'Server checks passed. For full client-path testing use: bash this-script e2e'
}
e2e() (
 set -Eeuo pipefail
 local ns=xgw-e2e d pub='' ip4 addr
 d=$(mktemp -d)
 cleanup_test() { [[ -z $pub ]] || wg set wg0 peer "$pub" remove; ip netns del "$ns" 2>/dev/null || true; ip link del xgw-e2e-h 2>/dev/null || true; rm -rf "$d"; }
 # Refuse collisions before touching test interfaces or client addresses.
 ip netns list | grep -q '^xgw-e2e\b' && die 'Test namespace already exists.'
 if ip link show xgw-e2e-h >/dev/null 2>&1; then die 'Test link already exists.'; fi
 wg show wg0 allowed-ips | grep -q '10.66.66.254/' && die 'Test IP .254 is occupied.'
 trap cleanup_test EXIT
 ip netns add "$ns"
 ip link add xgw-e2e-h type veth peer name xgw-e2e-n
 ip link set xgw-e2e-n netns "$ns"
 ip addr add 192.0.2.1/30 dev xgw-e2e-h; ip link set xgw-e2e-h up
 ip -n "$ns" addr add 192.0.2.2/30 dev xgw-e2e-n
 ip -n "$ns" link set xgw-e2e-n up; ip -n "$ns" link set lo up
 wg genkey > "$d/key"; pub=$(wg pubkey < "$d/key")
 wg set wg0 peer "$pub" allowed-ips 10.66.66.254/32
 ip -n "$ns" link add wgt type wireguard
 ip netns exec "$ns" wg set wgt private-key "$d/key" peer "$(wg show wg0 public-key)" endpoint "192.0.2.1:$(wg show wg0 listen-port)" allowed-ips 0.0.0.0/0 persistent-keepalive 25
 ip -n "$ns" addr add 10.66.66.254/32 dev wgt; ip -n "$ns" link set wgt mtu 1380 up
 ip -n "$ns" route add default dev wgt
 for mode in '' +tcp; do
  result=$(ip netns exec "$ns" dig @1.1.1.1 api.ipify.org $mode +time=8 +tries=1)
  grep -q 'status: NOERROR' <<< "$result"; grep -Eq 'ANSWER: [1-9]' <<< "$result"
 done
 ip4=$(ip netns exec "$ns" dig @10.66.66.1 api.ipify.org A +short | tail -1)
 for scheme in http https; do
  port=80; [[ $scheme != https ]] || port=443
  result=$(ip netns exec "$ns" curl -4fsS --max-time 25 --resolve "api.ipify.org:$port:$ip4" "$scheme://api.ipify.org")
  log "WireGuard $scheme exit: $result"
 done
 ip netns exec "$ns" wg show wgt
 log 'Temporary WireGuard handshake, intercepted DNS, HTTP and HTTPS passed. This does not test the mobile ISP path.'
)
status() {
 log "Version $VERSION"
 for unit in xray unbound wg-quick@wg0 xray-gateway-manager; do systemctl is-active "$unit" || true; systemctl is-enabled "$unit" || true; done
 wg show; ip -br addr; ss -lntup
 nft list table ip xgw || true; nft list table inet xgw_filter || true
}
uninstall() {
 local answer
 read -r -p 'Remove gateway integration, retaining Xray/WireGuard and peers? [y/N]: ' answer
 [[ $answer == y || $answer == Y ]] || return 0
 begin
 systemctl disable --now xgw-limits.timer 2>/dev/null || true
 systemctl stop xgw-limits.service 2>/dev/null || true
 nft delete table inet xgw_limits 2>/dev/null || true
 rm -f /usr/local/libexec/xgw-limits.py /etc/systemd/system/xgw-limits.service /etc/systemd/system/xgw-limits.timer
 # Remove dependency first; stopping the rules unit must not stop WireGuard.
 rm -f "$WS"
 systemctl daemon-reload
 systemctl disable --now xray-gateway-manager
 nft delete table ip xgw 2>/dev/null || true
 nft delete table inet xgw_filter 2>/dev/null || true
 rm -f "$N" "$NS" "$U" "$US" /usr/local/libexec/xgw-apply /etc/sysctl.d/99-xray-gateway-manager.conf
 # Remove only manager-tagged inbounds/rules; retain outbounds and unrelated config.
 python3 - "$X" <<'PY'
import json,sys
p=sys.argv[1]; c=json.load(open(p)); tags={'transparent-in','socks-in','http-in','dns-dot-google','dns-dot-google2'}
c['inbounds']=[i for i in c.get('inbounds',[]) if i.get('tag') not in tags]
rules=[]
for r in c.get('routing',{}).get('rules',[]):
 if set(r.get('inboundTag',[]))&tags:
  r['inboundTag']=[x for x in r['inboundTag'] if x not in tags]
  if not r['inboundTag']: continue
 rules.append(r)
c.setdefault('routing',{})['rules']=rules
json.dump(c,open(p,'w'),indent=2)
PY
 /usr/local/bin/xray run -test -config "$X"
 rm -f "$XS"
 systemctl daemon-reload
 local olduser oldgroup
 olduser=$(systemctl show xray -p User --value); olduser=${olduser:-root}
 oldgroup=$(systemctl show xray -p Group --value); oldgroup=${oldgroup:-$(id -gn "$olduser")}
 chown "root:$oldgroup" "$X"; chmod 640 "$X"
 chown "$olduser:$oldgroup" /var/log/xray
 for f in /var/log/xray/access.log /var/log/xray/error.log; do [[ ! -f $f ]] || chown "$olduser:$oldgroup" "$f"; done
 systemctl restart xray unbound
 put ROUTING_MODE disabled
 commit
 log 'Integration removed; packages, keys, clients and backups retained. WireGuard no longer provides this gateway.'
}
quick() {
 requirements
 configure_proxy
 configure_wg
 configure_routing
 health
 e2e
 log 'Gateway setup completed. Use option 6 to create clients; option 15 shows saved configs and QR codes.'
}
show_banner() {
 local line i=0
 local -a colors=(96 94 95 91 93 92)
 while IFS= read -r line; do
  if [[ -t 1 ]]; then
   printf '\033[1;%sm%s\033[0m\n' "${colors[i % ${#colors[@]}]}" "$line"
  else
   printf '%s\n' "$line"
  fi
  i=$((i+1))
 done <<'BANNER'
  ____  ____           __  __                         __        ______
 |  _ \|  _ \          \ \/ /_ __ __ _ _   _          \ \      / / ___|
 | |_) | | | |  _____   \  /| '__/ _` | | | |  _____   \ \ /\ / / |  _
 |  __/| |_| | |_____|  /  \| | | (_| | |_| | |_____|   \ V  V /| |_| |
 |_|   |____/          /_/\_\_|  \__,_|\__, |            \_/\_/  \____|
                                       |___/
BANNER
 if [[ -t 1 ]]; then printf '\033[1;96m'; fi
 printf '┌────────────────────────┐\n│  PD - Xray WG Manager   │\n└───────────────────────┘\n'
 if [[ -t 1 ]]; then printf '\033[0m'; fi
}
menu() {
 local choice d
 while true; do
  show_banner
  printf '\nXray + WireGuard Manager %s\n1) Quick setup\n2) Install requirements / Xray\n3) Configure Xray proxy\n4) Configure WireGuard server\n5) Configure routing\n6) Create WireGuard client\n7) List clients\n8) Remove client\n9) Status\n10) Test proxy\n11) Backup\n12) Restore\n13) Uninstall\n14) Client traffic / expiry limits\n15) Show client config / QR\n0) Exit\n' "$VERSION"
  read -r -p 'Select: ' choice || return 0
  case $choice in
   1) quick;; 2) requirements;; 3) configure_proxy;; 4) configure_wg;; 5) configure_routing;;
   6) client_create;; 7) clients_list;; 8) client_remove;; 9) status;; 10) health; e2e;;
   11) backup;;
   12) find "$B" -maxdepth 1 -type d -name 'snapshot-*'; read -r -p 'Snapshot path: ' d; log "Safety snapshot: $(backup)"; restore_snapshot "$d";;
   13) uninstall;; 14) limits_menu;; 15) client_show;; 0) return 0;; *) log 'Invalid choice';;
  esac
 done
}
main() {
 [[ $EUID == 0 && -d /run/systemd/system ]] || die 'Run as root on Ubuntu/systemd.'
 platform_check
 mkdir -p "$S" "$C" "$B"; chmod 700 "$S" "$C" "$B"
 # Rollback must not wait on the lock of the operation it is undoing.
 if [[ ${1:-} == restore-internal ]]; then restore_snapshot "$2"; return; fi
 exec 9>/run/xgw-manager.lock
 flock -n 9 || die 'Another manager operation is running.'
 case ${1:-menu} in
  menu) menu;; quick) quick;; status) status;; test) health;; e2e) e2e;; routing) configure_routing;;
  backup) backup;; restore) restore_snapshot "${2:?Snapshot required}";;
  install-limits) ensure_requirements; begin; install_limits; commit;;
  limits) python3 /usr/local/libexec/xgw-limits.py "${@:2}";;
  client-show) client_show "${2:-}";;
  *) die 'Usage: bash script [menu|quick|routing|status|test|e2e|backup|restore PATH]';;
 esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
