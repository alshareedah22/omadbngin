#!/bin/bash

# Fast tests for dbctl: no Docker, no downloads, no real services. A fake native server in a
# temporary OMADBNGIN_HOME, and shims for docker, systemctl, wl-copy and hyprctl.
#
#   tests/test-fast.sh

set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
DBCTL="$here/dbctl"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export OMADBNGIN_HOME="$T/home"
export OMADBNGIN_BACKUP_DIR="$T/backups"
export OMADBNGIN_BINDINGS="$T/bindings.lua"
mkdir -p "$T/bin" "$OMADBNGIN_HOME/servers" "$OMADBNGIN_BACKUP_DIR"

cat >"$T/bin/docker" <<'EOF'
#!/bin/bash
exit 1
EOF
cat >"$T/bin/systemctl" <<EOF
#!/bin/bash
# is-active fails (no Docker); show reports every unit as active with a control group
case "\$*" in
*is-active*) exit 1 ;;
*show*)
  for u in "\${@: -\$((\$# - 3))}"; do
    printf 'Id=%s\nActiveState=active\nUnitFileState=enabled\nMemoryCurrent=1048576\nActiveEnterTimestamp=\nControlGroup=/fake/%s\n\n' "\$u" "\$u"
  done ;;
*) echo "\$*" >>"$T/systemctl.log" ;;
esac
EOF
cat >"$T/bin/wl-copy" <<EOF
#!/bin/bash
cat >"$T/clipboard"
EOF
cat >"$T/bin/hyprctl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

passed=0
failed=0
ok() { passed=$((passed + 1)); printf '  \e[32m✓\e[0m %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf '  \e[31m✗ %s\e[0m\n' "$1"; }
eq() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: got [$2], want [$3]"; fi; }
has() { if [[ $2 == *"$3"* ]]; then ok "$1"; else bad "$1: [$2] lacks [$3]"; fi; }
fails() { local d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

server() { # name engine port user password
  mkdir -p "$OMADBNGIN_HOME/servers/$1/data"
  jq -n --arg n "$1" --arg e "$2" --argjson p "$3" --arg u "$4" --arg pw "$5" \
    '{name: $n, engine: $e, version: "x", exact: "x.1", port: $p, user: $u, password: $pw, mode: "native", created: "2026-10-29T10:00:00Z"}' \
    >"$OMADBNGIN_HOME/servers/$1/server.json"
}
server pg postgresql 5432 postgres "s3'cr et"
server my mysql 3306 root ""
server rd redis 6379 default "pw"
server mq mariadb 3307 app "it's"

echo "Connection formats"
eq "url" "$("$DBCTL" conn pg url)" "postgresql://postgres:s3%27cr%20et@127.0.0.1:5432/postgres"
eq "env" "$("$DBCTL" conn pg env)" "DATABASE_URL=postgresql://postgres:s3%27cr%20et@127.0.0.1:5432/postgres"
has "laravel pgsql" "$("$DBCTL" conn pg laravel)" "DB_CONNECTION=pgsql"
has "laravel password" "$("$DBCTL" conn pg laravel)" "DB_PASSWORD=s3'cr et"
has "laravel mysql" "$("$DBCTL" conn my laravel)" "DB_CONNECTION=mysql"
has "laravel redis" "$("$DBCTL" conn rd laravel)" "REDIS_PASSWORD=pw"
has "django" "$("$DBCTL" conn pg django)" '"ENGINE": "django.db.backends.postgresql"'
has "django redis" "$("$DBCTL" conn rd django)" "RedisCache"
eq "jdbc" "$("$DBCTL" conn my jdbc)" "jdbc:mysql://127.0.0.1:3306/?user=root"
eq "cli quotes the password" "$("$DBCTL" conn pg cli)" "psql 'postgresql://postgres:s3%27cr%20et@127.0.0.1:5432/postgres'"
eq "cli mysql without password" "$("$DBCTL" conn my cli)" "mysql -h127.0.0.1 -P3306 -u'root'"
eq "env redis" "$("$DBCTL" conn rd env)" "REDIS_URL=redis://:pw@127.0.0.1:6379"
eq "cli escapes a quote in the password" "$("$DBCTL" conn mq cli)" "mariadb -h127.0.0.1 -P3307 -u'app' -p'it'\\''s'"
out=$(bash -c "set -- $("$DBCTL" conn mq cli); printf '%s|' \"\$@\"")
eq "the cli line parses back to the password" "$out" "mariadb|-h127.0.0.1|-P3307|-uapp|-pit's|"
for f in url env laravel django cli; do
  if "$DBCTL" conn rd "$f" >/dev/null 2>&1; then ok "conn rd $f exits 0"; else bad "conn rd $f exits non-zero"; fi
done
for f in url env laravel django jdbc cli; do
  if "$DBCTL" conn pg "$f" >/dev/null 2>&1; then ok "conn pg $f exits 0"; else bad "conn pg $f exits non-zero"; fi
done
: >"$T/clipboard"; "$DBCTL" copy rd laravel
has "copy laravel for default-user redis reaches the clipboard" "$(cat "$T/clipboard")" "REDIS_HOST=127.0.0.1"
if "$DBCTL" state >/dev/null && "$DBCTL" state --full >/dev/null && "$DBCTL" sizes >/dev/null; then ok "state, state --full and sizes exit 0"; else bad "state/sizes exit non-zero"; fi
fails "unknown format" "$DBCTL" conn pg nope
fails "no jdbc for redis" "$DBCTL" conn rd jdbc
fails "unknown server" "$DBCTL" conn nope url
"$DBCTL" copy my jdbc
eq "copy puts it on the clipboard" "$(cat "$T/clipboard")" "jdbc:mysql://127.0.0.1:3306/?user=root"

echo "Stacks"
"$DBCTL" stack add shop pg && "$DBCTL" stack add shop rd
eq "add" "$("$DBCTL" stack list)" '{"shop":["pg","rd"]}'
"$DBCTL" stack add other pg
eq "a server is in one stack" "$("$DBCTL" stack list)" '{"shop":["rd"],"other":["pg"]}'
"$DBCTL" stack remove pg
eq "remove drops empty stacks" "$("$DBCTL" stack list)" '{"shop":["rd"]}'
fails "bad stack name" "$DBCTL" stack add "a b" pg
fails "stack of an unknown server" "$DBCTL" stack add shop nope
: >"$T/systemctl.log"
"$DBCTL" stack stop shop
has "stack stop stops its servers" "$(cat "$T/systemctl.log")" "stop omadbngin-rd.service"
"$DBCTL" stack delete shop
eq "delete" "$("$DBCTL" stack list)" '{}'

echo "State"
"$DBCTL" stack add web my
state=$("$DBCTL" state)
eq "stack on each server" "$(jq -r '.services[] | select(.name == "my") | .stack' <<<"$state")" "web"
eq "stacks listed" "$(jq -c '.stacks' <<<"$state")" '["web"]'
eq "no stats without --full" "$(jq -r '.services[0] | has("cpuUsec")' <<<"$state")" "false"
eq "no size in state" "$(jq -r '[.services[] | has("size")] | any' <<<"$state")" "false"
eq "no internals leak" "$(jq -r '[.services[] | has("cgroup") or has("cid")] | any' <<<"$state")" "false"
full=$("$DBCTL" state --full)
eq "--full adds cpu and readiness" "$(jq -r '.services[0] | (has("cpuUsec") and has("ready"))' <<<"$full")" "true"
sizes=$("$DBCTL" sizes)
eq "sizes per native server" "$(jq -r 'has("pg") and has("my")' <<<"$sizes")" "true"
touch -d '10 minutes ago' "$OMADBNGIN_HOME/.sizes.json"
eq "sizes cache refreshes after 5 min" "$("$DBCTL" sizes | jq -r 'has("rd")')" "true"

mkdir -p "$OMADBNGIN_HOME/engines/redis/$(jq -r '.engines.redis["7"].version' "$here/engines.lock")"
eq "state works with only some engines installed" "$("$DBCTL" state | jq -c '.installed | map(.engine)')" '["redis"]'

echo "Ports and backups"
eq "port from a chosen start" "$("$DBCTL" port redis 7400)" "7400"
fails "bad port start ignored" test "$("$DBCTL" port redis abc)" = abc
touch "$OMADBNGIN_BACKUP_DIR/pg-20261029-100000.sql"
eq "backups read the backup folder" "$("$DBCTL" backups pg | jq -r '.[0].path')" "$OMADBNGIN_BACKUP_DIR/pg-20261029-100000.sql"

echo "Shortcut"
printf -- '-- mine\n' >"$OMADBNGIN_BINDINGS"
"$DBCTL" bind >/dev/null
has "bind adds the line" "$(cat "$OMADBNGIN_BINDINGS")" 'o.bind("SUPER + ALT + D", "OmaDBngin"'
has "bind twice" "$("$DBCTL" bind)" "already bound"
"$DBCTL" unbind >/dev/null
eq "unbind restores the file" "$(cat "$OMADBNGIN_BINDINGS")" "-- mine"
printf 'o.bind("SUPER + ALT + D", "Mine", "x")\n' >>"$OMADBNGIN_BINDINGS"
fails "bind refuses a taken key" "$DBCTL" bind

echo "First-run setup"
printf -- '-- mine\n' >"$OMADBNGIN_BINDINGS"
rm -f "$OMADBNGIN_HOME/.setup-done"
has "setup binds a free key" "$("$DBCTL" setup)" "bound: SUPER+ALT+D"
"$DBCTL" unbind >/dev/null
eq "setup runs once: after an unbind it adds nothing" "$("$DBCTL" setup)" "already set up"
eq "the file stays without the shortcut" "$(cat "$OMADBNGIN_BINDINGS")" "-- mine"
rm -f "$OMADBNGIN_HOME/.setup-done"
printf 'o.bind("SUPER + ALT + D", "Mine", "x")\n' >>"$OMADBNGIN_BINDINGS"
has "setup leaves a taken key alone" "$("$DBCTL" setup)" "is taken"
eq "and does not fail" "$("$DBCTL" setup >/dev/null; echo $?)" "0"

echo "Hyprland not answering"
H="$T/h2"; mkdir -p "$H/.config/hypr"; printf -- '-- mine\n' >"$H/.config/hypr/bindings.lua"
printf '#!/bin/bash\nexit 4\n' >"$T/bin/hyprctl"
out=$(HOME="$H" OMADBNGIN_HOME="$H/omadbngin" OMADBNGIN_BINDINGS="$H/.config/hypr/bindings.lua" "$DBCTL" setup 2>&1); rc=$?
eq "setup does not fail when hyprctl reload fails" "$rc" "0"
has "still binds" "$out" "bound: SUPER+ALT+D"
if [[ -e $H/omadbngin/.setup-done ]]; then ok "and marks it done"; else bad "and marks it done"; fi
printf '#!/bin/bash\nexit 0\n' >"$T/bin/hyprctl"

echo "Kept data of a removed server (--keep-data)"
mkdir -p "$OMADBNGIN_HOME/servers/gone.removed-20261029-100000/data"
jq '.name = "gone" | .port = 5999' "$OMADBNGIN_HOME/servers/pg/server.json" >"$OMADBNGIN_HOME/servers/gone.removed-20261029-100000/server.json"
eq "not listed as a server" "$("$DBCTL" state | jq -c '[.services[].name] | map(select(startswith("gone")))')" "[]"
eq "its port is free again" "$("$DBCTL" port postgresql 5999)" "5999"
eq "no size entry" "$(rm -f "$OMADBNGIN_HOME/.sizes.json"; "$DBCTL" sizes | jq -r 'keys | map(select(startswith("gone"))) | length')" "0"
rm -rf "$OMADBNGIN_HOME/servers/gone.removed-20261029-100000"

echo "A broken server.json"
mkdir -p "$OMADBNGIN_HOME/servers/bad"
printf '{oops' >"$OMADBNGIN_HOME/servers/bad/server.json"
out=$("$DBCTL" state 2>/dev/null); rc=$?
eq "state still succeeds" "$rc" "0"
eq "the others are listed" "$(jq -r '[.services[].name] | (index("pg") != null and index("my") != null and index("bad") == null)' <<<"$out")" "true"
rm -rf "$OMADBNGIN_HOME/servers/bad"

echo "Backups of similar names"
touch "$OMADBNGIN_BACKUP_DIR/app-20261029-100000.sql" "$OMADBNGIN_BACKUP_DIR/app-staging-20261029-100000.sql" \
  "$OMADBNGIN_BACKUP_DIR/app-20261029-100000.rdb" "$OMADBNGIN_BACKUP_DIR/app-notes.sql"
eq "only the exact name and timestamp" "$("$DBCTL" backups app | jq -c '[.[].path | sub(".*/"; "")] | sort')" '["app-20261029-100000.rdb","app-20261029-100000.sql"]'
eq "the other server's own backups" "$("$DBCTL" backups app-staging | jq -c '[.[].path | sub(".*/"; "")]')" '["app-staging-20261029-100000.sql"]'

echo "Shortcut file that is a symlink"
printf -- '-- real\n' >"$T/real-bindings.lua"
ln -s real-bindings.lua "$T/link-bindings.lua"
OMADBNGIN_BINDINGS="$T/link-bindings.lua" "$DBCTL" bind >/dev/null
if [[ -L $T/link-bindings.lua ]]; then ok "bind keeps the symlink"; else bad "bind replaced the symlink"; fi
has "and writes through it" "$(cat "$T/real-bindings.lua")" 'o.bind("SUPER + ALT + D", "OmaDBngin"'
OMADBNGIN_BINDINGS="$T/link-bindings.lua" "$DBCTL" unbind >/dev/null
if [[ -L $T/link-bindings.lua ]]; then ok "unbind keeps the symlink"; else bad "unbind replaced the symlink"; fi
eq "unbind restores the target" "$(cat "$T/real-bindings.lua")" "-- real"

echo "Moving from OmaDB (setup runs first)"
M="$T/mig"; mkdir -p "$M/h" "$M/xdg" "$M/new" "$M/legacy/servers/old/data"
redis_v=$(jq -r '.engines.redis["7"].version' "$here/engines.lock")
jq -n --arg e "$redis_v" '{name: "old", engine: "redis", version: "7", exact: $e, port: 6401, user: "default", password: "", mode: "native", created: "2026-10-01T10:00:00Z"}' \
  >"$M/legacy/servers/old/server.json"
: >"$M/new/.setup-done" # what `dbctl setup` leaves behind before the first `state`
out=$(HOME="$M/h" XDG_RUNTIME_DIR="$M/xdg" OMADBNGIN_HOME="$M/new" OMADBNGIN_LEGACY_HOME="$M/legacy" "$DBCTL" state 2>/dev/null)
eq "the old server arrives although the directory existed" "$(jq -r '.services[0].name' <<<"$out" 2>/dev/null)" "old"
if [[ ! -e $M/legacy ]]; then ok "the legacy directory is gone"; else bad "the legacy directory is still there"; fi
if [[ -e $M/new/.migrated && -e $M/new/.setup-done ]]; then ok "marker written, setup's marker kept"; else bad "markers"; fi
has "its unit was written" "$(cat "$M/h/.config/systemd/user/omadbngin-old.service" 2>&1)" "redis-server"
mkdir -p "$M/legacy/servers/again"
HOME="$M/h" XDG_RUNTIME_DIR="$M/xdg" OMADBNGIN_HOME="$M/new" OMADBNGIN_LEGACY_HOME="$M/legacy" "$DBCTL" state >/dev/null 2>&1
if [[ -d $M/legacy/servers/again ]]; then ok "once migrated, later runs leave a new legacy folder alone"; else bad "migrated twice"; fi
mkdir -p "$M/new2"
HOME="$M/h" XDG_RUNTIME_DIR="$M/xdg" OMADBNGIN_HOME="$M/new2" OMADBNGIN_LEGACY_HOME="$M/none" "$DBCTL" state >/dev/null 2>&1
if [[ -e $M/new2/.migrated ]]; then ok "nothing to move: the marker is written anyway"; else bad "no marker without legacy data"; fi

echo "Paths with spaces, long paths"
mkdir -p "$T/ssbin"
cat >"$T/ssbin/ss" <<'EOF'
#!/bin/bash
# "listening" once a unit exists (create waits for the port)
compgen -G "$HOME/.config/systemd/user/omadbngin-*.service" >/dev/null && echo LISTEN
exit 0
EOF
chmod +x "$T/ssbin/ss"
S="$T/h sp"
mkdir -p "$S/omadbngin/engines/redis/$redis_v/bin"
HOME="$S" XDG_RUNTIME_DIR="$T/xdg" OMADBNGIN_HOME="$S/omadbngin" PATH="$T/ssbin:$PATH" "$DBCTL" create redis 7 spc 6390 off native >/dev/null 2>&1
unitf="$S/.config/systemd/user/omadbngin-spc.service"
line=$(grep '^ExecStart=' "$unitf" 2>/dev/null)
eq "ExecStart words survive a space in HOME" "$(bash -c "set -- ${line#ExecStart=}; printf '%s|' \"\$@\"" 2>&1)" \
  "$S/omadbngin/engines/redis/$redis_v/bin/redis-server|$S/omadbngin/servers/spc/redis.conf|"
has "the redis config quotes the data directory" "$(cat "$S/omadbngin/servers/spc/redis.conf")" "dir \"$S/omadbngin/servers/spc/data\""

pg_v=$(jq -r '.engines.postgresql["18"].version' "$here/engines.lock")
L="$T/$(printf 'long-%.0s' {1..14})home"
mkdir -p "$L/engines/postgresql/$pg_v/bin" "$T/xdg"
printf '#!/bin/bash\nexit 0\n' >"$L/engines/postgresql/$pg_v/bin/initdb"
chmod +x "$L/engines/postgresql/$pg_v/bin/initdb"
HOME="$T/h lng" XDG_RUNTIME_DIR="$T/xdg" OMADBNGIN_HOME="$L" PATH="$T/ssbin:$PATH" "$DBCTL" create postgresql 18 lng 6391 off native >/dev/null 2>&1
unitf="$T/h lng/.config/systemd/user/omadbngin-lng.service"
has "a socket path that would be too long uses a short directory" "$(cat "$unitf" 2>&1)" "unix_socket_directories=$T/xdg/omadbngin-lng"
has "which systemd creates" "$(cat "$unitf" 2>&1)" "RuntimeDirectory=omadbngin-lng"
has "a short path keeps its own run directory" "$(cat "$S/.config/systemd/user/omadbngin-spc.service")" "ExecStart="
if grep -q RuntimeDirectory "$S/.config/systemd/user/omadbngin-spc.service"; then bad "short path got a RuntimeDirectory"; else ok "and no RuntimeDirectory"; fi

# ---- 1.7.3 hardening: restores, creation races, panel fields ----------------------------------
# Everything below runs against fakes: no real database, container or service is touched.

echo "SQL dumps: the checker refuses client-side commands"
CHK="$here/tools/check-sql-dump.py"
sqlcheck() { printf '%b' "$1" >"$T/check.sql"; python3 -I "$CHK" "$T/check.sql" 2>/dev/null; }
cat >"$T/good-dump.sql" <<'EOF'
\restrict AbC123
SET client_encoding = 'UTF8';
CREATE ROLE postgres;
\connect "my db"
CREATE TABLE t (a int, "B c" text);
COPY public.t (a, "B c") FROM stdin;
1	\N
2	back\\slash \! not a command
\.
INSERT INTO t VALUES (3, 'it''s C:\\x');
CREATE FUNCTION f() RETURNS text LANGUAGE sql AS $$ select '\!' $$;
/* \! */ -- \!
select E'a\'b\\' ;
\unrestrict AbC123
EOF
if python3 -I "$CHK" "$T/good-dump.sql"; then ok "a pg_dumpall-style dump passes"; else bad "a pg_dumpall-style dump passes"; fi
fails "a shell escape on its own line" sqlcheck 'select 1;\n\\! touch /tmp/pwned\n'
fails "a shell escape after SQL on the same line" sqlcheck 'select 1 \\! id\n'
fails "a shell escape after a statement on the same line" sqlcheck 'select 1; \\! id\n'
fails "\\g" sqlcheck 'select 1;\n\\g\n'
fails "\\o" sqlcheck '\\o /tmp/x\n'
fails "\\i" sqlcheck '\\i /etc/passwd\n'
fails "a backtick in \\connect" sqlcheck '\\connect `id`\n'
fails "a command hidden in a multi-line statement" sqlcheck 'select\n\\! id\n'
fails "a quote that depends on standard_conforming_strings" sqlcheck "select 'x\\\\'; \\\\! id\n"
fails "a COPY with more after the semicolon" sqlcheck 'COPY t FROM stdin; select 1;\n\\! id\n'
fails "a COPY that is not at a statement start" sqlcheck 'select\nCOPY t FROM stdin;\n\\! id\n\\.\n'
fails "COPY FROM PROGRAM" sqlcheck "COPY t FROM PROGRAM 'id';\n"
fails "text after the end-of-data marker" sqlcheck 'COPY t FROM stdin;\n1\n\\.x\n'
fails "a client encoding that hides backslashes" sqlcheck 'SET client_encoding = SJIS;\n'
fails "BEGIN ATOMIC bodies, which cannot be followed" sqlcheck 'CREATE FUNCTION f() RETURNS int BEGIN ATOMIC select 1; END;\n'
if sqlcheck 'select 1;\n-- \\! in a comment\nselect '"'"'\\!'"'"';\n'; then ok "backslashes in comments and strings are fine"; else bad "backslashes in comments and strings are fine"; fi

echo "Restoring a PostgreSQL dump"
server pgr postgresql 5440 postgres "pgpw"
pgbase="$OMADBNGIN_HOME/engines/postgresql/x.1"
mkdir -p "$pgbase/bin"
cat >"$pgbase/bin/psql" <<EOF
#!/bin/bash
cat >"$T/psql.in"
env >"$T/psql.env"
printf '%s\n' "\$*" >"$T/psql.args"
EOF
chmod +x "$pgbase/bin/psql"
rm -f "$T/pwned" "$T/psql.in"
printf 'select 1;\n\\! touch %s\n' "$T/pwned" >"$T/evil.sql"
if "$DBCTL" restore pgr "$T/evil.sql" >/dev/null 2>"$T/restore.err"; then bad "a dump with a shell escape is refused"; else ok "a dump with a shell escape is refused"; fi
has "and the error says why" "$(cat "$T/restore.err")" "commands for the psql client"
if [[ ! -e $T/psql.in && ! -e $T/pwned ]]; then ok "psql never saw it, nothing ran"; else bad "psql saw the refused dump"; fi
if SECRET_CANARY=leak HISTFILE=/x PGSSLMODE=disable "$DBCTL" restore pgr "$T/good-dump.sql" >/dev/null 2>&1; then ok "a plain dump restores"; else bad "a plain dump restores"; fi
eq "psql gets exactly the checked dump" "$(cat "$T/psql.in")" "$(cat "$T/good-dump.sql")"
has "psql runs without rc files and without prompting for a password" "$(cat "$T/psql.args")" "-X -q -w"
has "psql gets the password through its environment" "$(cat "$T/psql.env")" "PGPASSWORD=pgpw"
if grep -q 'SECRET_CANARY\|^PGSSLMODE\|^HISTFILE' "$T/psql.env"; then bad "psql runs with this account's environment"; else ok "psql runs with only the environment it needs"; fi
has "and no rc or history files" "$(cat "$T/psql.env")" "PSQLRC=/dev/null"
if grep -q "^HOME=$HOME\$" "$T/psql.env"; then bad "psql sees this account's home"; else ok "psql does not see this account's home"; fi

echo "Restoring MySQL and MariaDB"
server myr mysql 3310 root "rootpw"
mybase="$OMADBNGIN_HOME/engines/mysql/x.1"
mkdir -p "$mybase/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >"%s/mysql.args"\ncat >/dev/null\n' "$T" >"$mybase/bin/mysql"
chmod +x "$mybase/bin/mysql"
printf 'select 1;\n' >"$T/my.sql"
"$DBCTL" restore myr "$T/my.sql" >/dev/null 2>&1
has "the mysql client runs in binary mode (no \\! or system commands from the file)" "$(cat "$T/mysql.args")" "--binary-mode"

echo "Restoring a Redis snapshot (native)"
export OMADBNGIN_HEALTH_TRIES=3
server rdr redis 6450 default "rpw"
rbase="$OMADBNGIN_HOME/engines/redis/x.1"
mkdir -p "$rbase/bin"
cat >"$rbase/bin/redis-server" <<'EOF'
#!/bin/bash
# a throwaway server: refuses a snapshot containing CORRUPT, else "listens" on its socket
while (($#)); do case $1 in --dir) d=$2 ;; --unixsocket) s=$2 ;; --pidfile) p=$2 ;; esac; shift; done
grep -q CORRUPT "$d/dump.rdb" && exit 1
: >"$s"
sleep 30 &
echo $! >"$p"
EOF
cat >"$rbase/bin/redis-cli" <<EOF
#!/bin/bash
sock="" args="\$*"
[[ \$1 == -s ]] && sock=\$2
if [[ -n \$sock ]]; then
  case \$args in
  *shutdown*) kill "\$(cat "\$(dirname "\$sock")/pid" 2>/dev/null)" 2>/dev/null; rm -f "\$sock"; exit 0 ;;
  *ping*) [[ -e \$sock ]] && echo PONG || exit 1; exit 0 ;;
  *"info persistence"*) echo loading:0; exit 0 ;;
  esac
fi
[[ -e "$T/unhealthy" ]] && exit 1
case \$args in
*ping*) echo PONG ;;
*"info persistence"*) echo loading:0 ;;
*"config set appendonly yes"*) echo "config set" >>"$T/cli.log" ;;
esac
EOF
chmod +x "$rbase/bin/redis-server" "$rbase/bin/redis-cli"
rdata="$OMADBNGIN_HOME/servers/rdr/data"
rconf="$OMADBNGIN_HOME/servers/rdr/redis.conf"
reset_rdr() {
  rm -rf "$rdata"
  mkdir -p "$rdata/appendonlydir"
  printf 'REDIS-OLD' >"$rdata/dump.rdb"
  printf 'old-aof' >"$rdata/appendonlydir/a.aof"
  printf 'port 6450\nappendonly yes\n' >"$rconf"
  : >"$T/systemctl.log"
  rm -f "$T/unhealthy" "$T/cli.log"
}
printf 'REDIS0011CORRUPT' >"$T/bad.rdb"
printf 'REDIS0011GOOD' >"$T/good.rdb"

reset_rdr
if "$DBCTL" restore rdr "$T/bad.rdb" >/dev/null 2>&1; then bad "a snapshot the engine cannot load is refused"; else ok "a snapshot the engine cannot load is refused"; fi
eq "the server was never stopped" "$(grep -c stop "$T/systemctl.log")" "0"
eq "its data is untouched" "$(cat "$rdata/dump.rdb")|$(cat "$rdata/appendonlydir/a.aof")" "REDIS-OLD|old-aof"
eq "and so is its config" "$(cat "$rconf")" $'port 6450\nappendonly yes'

reset_rdr
: >"$T/unhealthy"
out=$("$DBCTL" restore rdr "$T/good.rdb" 2>&1); rc=$?
if ((rc != 0)); then ok "a restored server that does not come up fails the restore"; else bad "a restored server that does not come up fails the restore"; fi
has "and says the old data is back" "$out" "previous data is back"
eq "the old snapshot and log are back" "$(cat "$rdata/dump.rdb")|$(cat "$rdata/appendonlydir/a.aof")" "REDIS-OLD|old-aof"
eq "the config is back" "$(cat "$rconf")" $'port 6450\nappendonly yes'
eq "nothing is left aside" "$(ls -A "$rdata" | sort | tr '\n' ' ')" "appendonlydir dump.rdb "
eq "the server was started again" "$(grep -c -- ' start ' "$T/systemctl.log")" "2"

reset_rdr
if "$DBCTL" restore rdr "$T/good.rdb" >/dev/null 2>&1; then ok "a healthy restore succeeds"; else bad "a healthy restore succeeds"; fi
eq "the new snapshot is in place" "$(cat "$rdata/dump.rdb")" "REDIS0011GOOD"
eq "the append-only log setting is back on" "$(cat "$rconf")" $'port 6450\nappendonly yes'
has "in the running server too" "$(cat "$T/cli.log" 2>/dev/null)" "config set"
eq "the old files are removed only now" "$(ls -A "$rdata" | tr '\n' ' ')" "dump.rdb "
unset OMADBNGIN_HEALTH_TRIES

echo "Restoring a Redis snapshot (Docker)"
mkdir -p "$T/dk"
cat >"$T/dk/docker" <<EOF
#!/bin/bash
echo "\$*" >>"$T/docker.log"
case \$1 in
inspect)
  case \$* in
  *omadbngin.managed*) echo 1 ;;
  *omadbngin.engine*) echo redis ;;
  *omadbngin.port*) echo 6451 ;;
  *omadbngin.user*) echo default ;;
  *omadbngin.password*) echo rpw ;;
  *Config.Image*) echo "redis@sha256:\$(printf 'a%.0s' {1..64})" ;;
  esac ;;
run)
  case \$* in
  *"/in.rdb"*) [[ -e "$T/dk-bad" ]] && exit 1 ;;
  *omadbngin-restore.rdb*) [[ -e "$T/dk-swapfail" ]] && exit 1 ;;
  esac ;;
exec)
  case \$* in
  *"rm -rf"*) ;;
  *ping*) [[ -e "$T/dk-unhealthy" ]] && exit 1; echo PONG ;;
  *"info persistence"*) echo loading:0 ;;
  esac ;;
esac
exit 0
EOF
chmod +x "$T/dk/docker"
dkrestore() { OMADBNGIN_HEALTH_TRIES=2 PATH="$T/dk:$PATH" "$DBCTL" restore rdd "$T/good.rdb" 2>&1; }
dkreset() { : >"$T/docker.log"; rm -f "$T/dk-bad" "$T/dk-swapfail" "$T/dk-unhealthy"; }
dkreset
: >"$T/dk-bad"
if dkrestore >/dev/null; then bad "docker: a snapshot the engine cannot load is refused"; else ok "docker: a snapshot the engine cannot load is refused"; fi
eq "docker: the container was never stopped" "$(grep -c '^stop' "$T/docker.log")" "0"
dkreset
: >"$T/dk-swapfail"
if dkrestore >/dev/null; then bad "docker: a failed load fails the restore"; else ok "docker: a failed load fails the restore"; fi
has "docker: the old files are put back" "$(cat "$T/docker.log")" 'rm -rf dump.rdb appendonlydir'
eq "docker: and the container is started again" "$(tail -1 "$T/docker.log" | cut -d' ' -f1)" "start"
dkreset
: >"$T/dk-unhealthy"
if dkrestore >/dev/null; then bad "docker: a restored container that does not answer fails the restore"; else ok "docker: a restored container that does not answer fails the restore"; fi
if grep -q '^exec -u 0' "$T/docker.log"; then bad "docker: the old data is kept when the restore is unhealthy"; else ok "docker: the old data is kept when the restore is unhealthy"; fi
has "docker: it is put back" "$(cat "$T/docker.log")" 'rm -rf dump.rdb appendonlydir'
dkreset
if dkrestore >/dev/null; then ok "docker: a healthy restore succeeds"; else bad "docker: a healthy restore succeeds"; fi
last=$(tail -1 "$T/docker.log")
has "docker: the old files are removed last, after the container answered" "$last" "exec -u 0"
has "docker: and only the kept ones" "$last" "rm -rf /data/.pre-restore-"

echo "Creating servers: one at a time, undoing only its own work"
CR="$T/cr"
mkdir -p "$CR/home" "$CR/xdg" "$CR/ssnone" "$CR/ss" "$CR/slow" "$CR/h"
redis_v=$(jq -r '.engines.redis["7"].version' "$here/engines.lock")
mkdir -p "$CR/home/engines/redis/$redis_v/bin"
printf '#!/bin/bash\nexit 0\n' >"$CR/ssnone/ss"
printf '#!/bin/bash\ncompgen -G "$HOME/.config/systemd/user/omadbngin-*.service" >/dev/null && echo LISTEN\nexit 0\n' >"$CR/ss/ss"
printf '#!/bin/bash\n[[ " $* " == *" start "* ]] && sleep 1.2\nexec "%s/bin/systemctl" "$@"\n' "$T" >"$CR/slow/systemctl"
chmod +x "$CR/ssnone/ss" "$CR/ss/ss" "$CR/slow/systemctl"
crenv() { HOME="$CR/h" XDG_RUNTIME_DIR="$CR/xdg" OMADBNGIN_HOME="$CR/home" "$@"; }

mkdir -p "$CR/home/servers/foreign/data"
printf 'precious' >"$CR/home/servers/foreign/data/file"
if crenv env PATH="$CR/ss:$PATH" "$DBCTL" create redis 7 foreign 6460 off native >/dev/null 2>&1; then bad "a name whose folder exists is refused"; else ok "a name whose folder exists is refused"; fi
eq "the folder somebody else made is left alone" "$(cat "$CR/home/servers/foreign/data/file" 2>/dev/null)" "precious"

: >"$T/systemctl.log"
if crenv env PATH="$CR/ssnone:$PATH" "$DBCTL" create redis 7 doomed 6461 off native >/dev/null 2>&1; then bad "a server that never listens fails the create"; else ok "a server that never listens fails the create"; fi
if [[ ! -e $CR/home/servers/doomed && ! -e $CR/h/.config/systemd/user/omadbngin-doomed.service ]]; then ok "its folder and unit are removed again"; else bad "its folder and unit are removed again"; fi
has "and its service is stopped" "$(cat "$T/systemctl.log")" "disable --now --quiet omadbngin-doomed.service"

rm -rf "$CR/home/servers/foreign"
crenv env PATH="$CR/slow:$CR/ss:$PATH" "$DBCTL" create redis 7 twin 6462 off native >"$CR/a.out" 2>&1 &
apid=$!
sleep 0.4
t0=$(date +%s%N)
crenv env PATH="$CR/slow:$CR/ss:$PATH" "$DBCTL" create redis 7 twin 6463 off native >"$CR/b.out" 2>&1
brc=$?
t1=$(date +%s%N)
wait "$apid"
arc=$?
eq "of two creates of one name, the first succeeds" "$arc" "0"
if ((brc != 0)); then ok "the second fails"; else bad "the second fails"; fi
has "because the name is taken" "$(cat "$CR/b.out")" "already exists"
if (((t1 - t0) / 1000000 > 400)); then ok "the second waited for the first (serialized)"; else bad "the second did not wait ($(((t1 - t0) / 1000000)) ms)"; fi
eq "the first one's server is intact" "$(jq -r '.name + ":" + (.port | tostring)' "$CR/home/servers/twin/server.json" 2>/dev/null)" "twin:6462"
if [[ -e $CR/h/.config/systemd/user/omadbngin-twin.service ]]; then ok "and so is its unit"; else bad "and so is its unit"; fi

# Docker, against a fake that keeps its containers and volumes as files
D="$T/fd"
mkdir -p "$D/bin" "$D/containers" "$D/volumes" "$D/home" "$D/h" "$D/xdg" "$D/ss"
cat >"$D/bin/docker" <<EOF
#!/bin/bash
D="$D"
ARGS="\$*"
case \$1 in
info) exit 0 ;;
ps) exit 0 ;;
inspect)
  n=\${@: -1}
  [[ -e \$D/containers/\$n ]] || exit 1
  case \$* in
  *omadbngin.managed*) [[ -e \$D/managed-\$n ]] && echo 1 ;;
  *omadbngin.create*) cat "\$D/containers/\$n" ;;
  esac ;;
volume)
  case \$2 in
  inspect) n=\${@: -1}; [[ -e \$D/volumes/\$n ]] || exit 1; case \$* in *omadbngin.create*) cat "\$D/volumes/\$n" ;; esac ;;
  create) grep -o 'omadbngin.create=[^ ]*' <<<"\$ARGS" | cut -d= -f2 >"\$D/volumes/\${@: -1}" ;;
  rm) rm -f "\$D/volumes/\${@: -1}" ;;
  esac ;;
rm) rm -f "\$D/containers/\${@: -1}" ;;
run)
  case \$ARGS in
  *" -d "*)
    while ((\$#)); do [[ \$1 == --name ]] && n=\$2; shift; done
    [[ -e \$D/containers/\$n ]] && { echo "name in use" >&2; exit 125; }
    if [[ -e \$D/raced ]]; then echo foreign >"\$D/containers/\$n"; echo "name in use" >&2; exit 125; fi
    grep -o 'omadbngin.create=[^ ]*' <<<"\$ARGS" | cut -d= -f2 >"\$D/containers/\$n"
    [[ -e \$D/runfails ]] && exit 1 ;;
  *) cat >/dev/null ;;
  esac ;;
esac
exit 0
EOF
chmod +x "$D/bin/docker"
cp "$CR/ss/ss" "$D/ss/ss"
dkenv() { HOME="$D/h" XDG_RUNTIME_DIR="$D/xdg" OMADBNGIN_HOME="$D/home" DOCKER_HOST=unix:///nonexistent PATH="$D/bin:$D/ss:$PATH" "$@"; }

# a container and a volume that appear after the name was checked, and are not this attempt's
: >"$D/volumes/omadbngin-dock"
: >"$D/raced"
if dkenv "$DBCTL" create redis 7 dock 6470 off docker >/dev/null 2>&1; then bad "docker: a container that appears meanwhile fails the create"; else ok "docker: a container that appears meanwhile fails the create"; fi
if [[ -e $D/containers/omadbngin-dock && -e $D/volumes/omadbngin-dock ]]; then ok "docker: the container and volume that were not ours are left alone"; else bad "docker: the container and volume that were not ours are left alone"; fi
rm -f "$D/containers/omadbngin-dock" "$D/volumes/omadbngin-dock" "$D/raced"
: >"$D/runfails"
if dkenv "$DBCTL" create redis 7 dock2 6471 off docker >/dev/null 2>&1; then bad "docker: a failing run fails the create"; else ok "docker: a failing run fails the create"; fi
if [[ ! -e $D/containers/omadbngin-dock2 && ! -e $D/volumes/omadbngin-dock2 ]]; then ok "docker: what the attempt made is removed again"; else bad "docker: what the attempt made is removed again"; fi

echo "The panel's text fields"
if grep -nE '^\s*TextField \{' "$here/Panel.qml" >/dev/null; then bad "Panel.qml has a bare TextField"; else ok "every field in Panel.qml is a SafeField (built only while the panel is open)"; fi
has "the new-server password is masked by default" "$(grep -A8 'id: passField' "$here/Panel.qml" | tr '\n' ' ')" 'secret: !root.showPass'
has "and shown only after a click" "$(grep 'property bool showPass' "$here/Panel.qml")" "showPass: false"
has "closing the panel clears the drafts" "$(sed -n '/^  onOpenedChanged/,/^  }/p' "$here/Panel.qml")" 'passField.text = ""'
has "and the password's visibility" "$(sed -n '/^  onOpenedChanged/,/^  }/p' "$here/Panel.qml")" 'root.showPass = false'
has "a paste is fetched by a size- and time-limited process" "$(grep -A8 'function pasteInto' "$here/Panel.qml")" 'head -c 1024'
if [[ -x /usr/lib/qt6/bin/qmltestrunner ]]; then
  Q="$T/qml"
  mkdir -p "$Q"
  cp -r "$here/tests/qml/." "$Q/"
  cp "$here/SafeField.qml" "$Q/"
  if (cd "$Q" && QT_QPA_PLATFORM=offscreen timeout 120 /usr/lib/qt6/bin/qmltestrunner -import stub -platform offscreen >"$Q/out" 2>&1); then ok "SafeField tests ($(grep -c '^PASS' "$Q/out") checks)"; else bad "SafeField tests: $(grep -E '^FAIL' "$Q/out" | head -3)"; fi
else
  echo "  (qmltestrunner not installed: SafeField tests skipped)"
fi

echo
echo "$passed passed, $failed failed"
((failed == 0))
