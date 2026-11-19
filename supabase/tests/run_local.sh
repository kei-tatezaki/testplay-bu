#!/bin/bash
# 使い捨てのローカルPostgresで supabase/*.sql を番号順に通す（root で動かしても postgres ユーザーで動く）
# 使い方: bash supabase/tests/run_local.sh [追加で流すSQLファイル...]   → 終わると DB を消す
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | tail -1)
DIR=$(mktemp -d); chown postgres "$DIR"
PORT=54329
runuser -u postgres -- $PGBIN/initdb -D "$DIR/data" -A trust >/dev/null
runuser -u postgres -- $PGBIN/pg_ctl -D "$DIR/data" -o "-p $PORT -k $DIR -c listen_addresses=''" -l "$DIR/log" -w start >/dev/null
trap 'runuser -u postgres -- $PGBIN/pg_ctl -D "$DIR/data" -m immediate stop >/dev/null; rm -rf "$DIR"' EXIT
P="psql -h $DIR -p $PORT -U postgres -v ON_ERROR_STOP=1 -q -X"
runuser -u postgres -- $P -c "create database t" 
Q="runuser -u postgres -- psql -h $DIR -p $PORT -U postgres -d t -v ON_ERROR_STOP=1 -q -X"
$Q -f "$D/tests/local_stub.sql"
for f in "$D"/0*.sql; do echo "== $(basename $f)"; $Q -f "$f" >/dev/null; done
for f in "$@"; do echo "== $f"; $Q -f "$f"; done
