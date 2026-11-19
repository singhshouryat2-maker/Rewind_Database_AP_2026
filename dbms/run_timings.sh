#!/usr/bin/env bash
# Times every query in dbms/04_queries.sql 3 times with EXPLAIN (ANALYZE, BUFFERS).
# Writes the raw plans to dbms/plans/<id>.txt and the table to dbms/05_query_timings.md.
# Every query runs inside BEGIN ... ROLLBACK, so the data does not change.
#
# Usage: ./dbms/run_timings.sh <database>
set -euo pipefail

DB="${1:?database name required}"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/plans"
MD="$DIR/05_query_timings.md"
mkdir -p "$OUT"

# Split 04_queries.sql on the "-- @R1" / "-- @W1" markers into one file per query
TMP="$(mktemp -d)"
awk -v dir="$TMP" '
  /^-- @END/ { id = ""; next }
  /^-- @[RW][0-9]+/ { id = substr($2, 2); next }
  id != "" && /^-- (READ|WRITE):/ { sub(/^-- (READ|WRITE): /, ""); print > (dir "/" id ".desc"); next }
  id != "" && /^SET rewind\./ { print >> (dir "/" id ".set"); next }
  id != "" && !/^--/ && NF { print >> (dir "/" id ".sql") }
' "$DIR/04_queries.sql"

{
  echo "# 05 · Query timings: Rewind Database"
  echo
  echo "Each query from \`dbms/04_queries.sql\` ran 3 times with \`EXPLAIN (ANALYZE, BUFFERS)\` inside \`BEGIN … ROLLBACK\`."
  echo "Data: \`dbms/seed_data.sql\` (10,000 employees, about 22,000 history rows). Raw plans: \`dbms/plans/\`."
  echo
  echo "| Query | Type | What it does | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) | Scan type |"
  echo "|-------|------|--------------|-----------:|-----------:|-----------:|-------------:|-----------|"
} > "$MD"

for f in $(ls "$TMP"/*.sql | sort -V); do
  id="$(basename "$f" .sql)"
  type="READ"; [[ "$id" == W* ]] && type="WRITE"
  desc="$(cat "$TMP/$id.desc")"
  setsql="$(cat "$TMP/$id.set" 2>/dev/null || true)"
  query="$(cat "$f")"
  : > "$OUT/$id.txt"
  times=()
  for i in 1 2 3; do
    plan="$(printf 'BEGIN;\n%s\nEXPLAIN (ANALYZE, BUFFERS) %s\nROLLBACK;\n' "$setsql" "$query" \
            | psql -d "$DB" -X -q -A -t -v ON_ERROR_STOP=1)"
    echo "=== $id run $i ===" >> "$OUT/$id.txt"
    echo "$plan" >> "$OUT/$id.txt"
    times+=("$(echo "$plan" | grep -oE 'Execution Time: [0-9.]+' | awk '{print $3}')")
  done
  avg="$(printf '%s\n' "${times[@]}" | awk '{ s += $1 } END { printf "%.3f", s / NR }')"
  scan="$(echo "$plan" | grep -oE '(Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan)( using [a-z0-9_]+)? on [a-z_]+' \
          | awk '!seen[$0]++' | paste -sd',' - | sed 's/,/, /g' || true)"
  scan="${scan:-—}"
  echo "| $id | $type | $desc | ${times[0]} | ${times[1]} | ${times[2]} | $avg | $scan |" >> "$MD"
  printf '%-4s %-5s avg %9s ms   %s\n' "$id" "$type" "$avg" "$scan"
done

rm -rf "$TMP"
echo "Saved $MD and raw plans to $OUT"
