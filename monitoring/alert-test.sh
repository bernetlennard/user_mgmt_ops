#!/usr/bin/env bash
# Alert test (Aufgabe 1): assigns a module in staging once per second and logs status code and
# response time, so a module_service outage shows up as 200 -> 503 -> 200. The 503s are what
# makes UserMgmtBackendHighErrorRate fire.
#
#   bash monitoring/alert-test.sh [count]    # Git Bash; without count it runs until Ctrl+C
#
# Output is also written to ~/alert-test.log. Uses the k6 test user (k6/README.md) and only
# ever talks to staging. The full procedure and the results of the run on 2026-09-25 are in
# monitoring/README.md, "Proof: a real alert, end to end".
API=https://vcs-staging.linosteiner.ch/api
MODULE=c02f58f2-3aca-4f1e-8076-bacf6f1999e6 # CLOUD-ARCH, seeded by the module_service
COUNT=${1:-0}

TOKEN=$(curl -s -D - -o /dev/null -X POST "$API/users/login" -H 'Content-Type: application/json' \
  -d '{"email":"k6-loadtest@user-mgmt.local","password":"K6LoadTest123!"}' |
  grep -i '^authorization:' | sed 's/.*Bearer //' | tr -d '\r')
if [ -z "$TOKEN" ]; then
  echo "Login failed. Is the k6 test user registered in staging? See k6/README.md." >&2
  exit 1
fi
ME=$(curl -s "$API/users/me" -H "Authorization: Bearer $TOKEN" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "Test user $ME: PUT /users/$ME/modules/$MODULE once per second. Stop with Ctrl+C."
echo "time (UTC)  status  duration"

i=0
while [ "$COUNT" -eq 0 ] || [ "$i" -lt "$COUNT" ]; do
  echo "$(date -u +%H:%M:%S)    $(curl -s -o /dev/null -w '%{http_code}     %{time_total}s' -X PUT "$API/users/$ME/modules/$MODULE" -H "Authorization: Bearer $TOKEN")"
  i=$((i + 1))
  sleep 1
done | tee ~/alert-test.log
