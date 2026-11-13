#!/bin/bash
# Read-only snapshot of how WEB/WAS is built on this host, printed as key=value lines.
# The same script runs on the old and the new VM so validate.yml can compare them key by key.
# Usage: state_snapshot.sh APACHE_BIN TOMCAT_HOME HTTP_PORTS(comma separated)
APACHE_BIN="${1:-/data/httpd/bin/httpd}"
TOMCAT_HOME="${2:-/data/tomcat}"
HTTP_PORTS="${3:-80,8080}"
APACHE_ROOT="$(dirname "$(dirname "$APACHE_BIN")")"

emit() { printf '%s=%s\n' "$1" "$2"; }
join() { paste -sd'|' -; }
norm() { sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//'; }
strip() { grep -Ev '^[[:space:]]*(#|$)' "$1" 2>/dev/null | norm; }

# Service accounts: uid:gid:home:shell must match so file ownership carries over
for u in apache tomcat; do
  emit "account.$u" "$(id -u "$u" 2>/dev/null):$(id -g "$u" 2>/dev/null):$(getent passwd "$u" | cut -d: -f6,7)"
done

# Apache: version, MPM, loaded modules, effective configuration, virtual hosts
emit apache.version "$("$APACHE_BIN" -v 2>/dev/null | awk '/version/{print $3}')"
emit apache.mpm "$("$APACHE_BIN" -V 2>/dev/null | awk -F': *' '/Server MPM/{print $2}')"
emit apache.root "$("$APACHE_BIN" -V 2>/dev/null | awk -F'"' '/HTTPD_ROOT/{print $2}')"
emit apache.modules "$("$APACHE_BIN" -M 2>/dev/null | awk '/_module/{print $1}' | sort | join)"
# ServerName is compared separately: its position in the file does not matter (the old VM has it near the end,
# the role replaces the commented default line in place), but its value does
emit apache.conf "$(strip "$APACHE_ROOT/conf/httpd.conf" | grep -v '^ServerName ' | join)"
emit apache.servername "$(strip "$APACHE_ROOT/conf/httpd.conf" | grep '^ServerName ' | join)"
emit apache.vhosts "$("$APACHE_BIN" -S 2>&1 | grep -E 'port|namevhost|^User|^Group|Main' | norm | join)"
emit apache.compile "$("$APACHE_BIN" -V 2>/dev/null | sed -n '/Server compiled with/,$p' | tail -n +2 | norm | sort | join)"

# Tomcat: install directory, unmodified config files (checksums), setenv.sh, webapps, jars, running JVM
JAVA_BIN="/usr/lib/jvm/jre/bin/java"
[ -x "$JAVA_BIN" ] || JAVA_BIN="$(command -v java)"
emit tomcat.dir "$(basename "$(readlink -f "$TOMCAT_HOME")")"
emit tomcat.conf "$(cd "$TOMCAT_HOME/conf" 2>/dev/null && find . -type f -not -path './Catalina/*' | sort | xargs md5sum | awk '{print $2":"substr($1,1,8)}' | join)"
# JAVA_HOME is compared separately: the old path contains the exact el8 JDK build, which cannot exist on Rocky 9
emit tomcat.setenv "$(strip "$TOMCAT_HOME/bin/setenv.sh" | grep -v '^export JAVA_HOME=' | join)"
emit tomcat.java_home "$(grep -h '^export JAVA_HOME=' "$TOMCAT_HOME/bin/setenv.sh" 2>/dev/null)"
emit tomcat.webapps "$(ls "$TOMCAT_HOME/webapps" 2>/dev/null | sort | join)"
emit tomcat.lib "$(ls "$TOMCAT_HOME/lib" 2>/dev/null | sort | md5sum | cut -c1-8)"
emit java.major "$("$JAVA_BIN" -version 2>&1 | awk -F'"' '/version/{split($2,a,"."); print a[1]}')"
TPID="$(systemctl show -p MainPID --value tomcat 2>/dev/null)"
if [ -n "$TPID" ] && [ "$TPID" != "0" ]; then
  emit tomcat.cmdline "$(tr '\0' ' ' < "/proc/$TPID/cmdline" | sed -e 's#/usr/lib/jvm/[^/]*/#/usr/lib/jvm/JDK/#' | norm)"
else
  emit tomcat.cmdline "(not running)"
fi

# systemd units: effective definition and state
for u in httpd-custom tomcat; do
  emit "unit.$u" "$(systemctl cat "$u" 2>/dev/null | grep -Ev '^[[:space:]]*(#|$)' | norm | join)"
  emit "unit.$u.enabled" "$(systemctl is-enabled "$u" 2>/dev/null)"
  emit "unit.$u.active" "$(systemctl is-active "$u" 2>/dev/null)"
done

# SELinux: mode, boolean, local file contexts, process domains
emit selinux.mode "$(getenforce 2>/dev/null)"
emit selinux.bool.httpd_can_network_connect "$(getsebool httpd_can_network_connect 2>/dev/null | awk '{print $3}')"
emit selinux.fcontext "$(semanage fcontext -l -C 2>/dev/null | awk 'NF{print $1, $2, $NF}' | sort | join)"
emit selinux.domain.httpd "$(ps -eZ 2>/dev/null | awk '/ httpd$/{print $1}' | sort -u | join)"
emit selinux.domain.java "$(ps -eZ 2>/dev/null | awk '/ java$/{print $1}' | sort -u | join)"

# Firewall and basic system settings
emit firewall.services "$(firewall-cmd --list-services 2>/dev/null | tr ' ' '\n' | sort | join)"
emit firewall.ports "$(firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | sort | join)"
emit system.timezone "$(timedatectl show -p Timezone --value 2>/dev/null)"
emit system.crypto_policy "$(update-crypto-policies --show 2>/dev/null)"
emit sshd.permitrootlogin "$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')"

# Ownership and mode of the key paths
emit fs.perm "$(stat -L -c '%U:%G:%a:%n' /data "$TOMCAT_HOME" "$TOMCAT_HOME/conf" "$TOMCAT_HOME/logs" "$TOMCAT_HOME/temp" \
  "$TOMCAT_HOME/work" "$TOMCAT_HOME/webapps" "$TOMCAT_HOME/bin/startup.sh" "$APACHE_ROOT/conf" "$APACHE_ROOT/logs" \
  "$APACHE_ROOT/htdocs" "$APACHE_BIN" 2>/dev/null | join)"

# Listening ports and HTTP responses (the first request is a warm-up)
emit ports "$(ss -lntH | awk '{print $4}' | awk -F: '{print $NF}' | sort -un | join)"
IFS=',' read -ra PORT_LIST <<< "$HTTP_PORTS"
for p in "${PORT_LIST[@]}"; do
  if ! command -v curl >/dev/null 2>&1; then emit "resp.code.$p" "no-curl"; continue; fi
  url="http://127.0.0.1:$p/"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)"
  total=0
  for _ in 1 2 3; do
    t="$(curl -s -o /dev/null -w '%{time_total}' --max-time 10 "$url" 2>/dev/null)"
    total="$(awk -v a="$total" -v b="${t:-0}" 'BEGIN{print a+b}')"
  done
  emit "resp.code.$p" "$code"
  emit "resp.time.$p" "$(awk -v a="$total" 'BEGIN{printf "%.3f", a/3}')"
done
