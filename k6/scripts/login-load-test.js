// Aufgabe 2 Chaos Testing: controlled, ramping load against a real business endpoint of
// user_mgmt_service, run through the public ingress (same path a real client takes).
//
// Endpoint: POST /api/users/login. Chosen over the other candidates because it's the only
// one that is simultaneously (a) unauthenticated -- no token bootstrap needed in the script
// -- (b) non-mutating on every call -- login only reads the user row and verifies the bcrypt
// hash, it writes nothing -- and (c) real business logic (bcrypt verification + JWT signing
// is a genuine, non-trivial CPU cost per request, which is what makes it useful for driving
// the HPA's CPU-utilization target). POST /users/register was ruled out because every call
// inserts a row; the authenticated GET endpoints were ruled out because they'd need a token
// bootstrap stage for no real benefit.
//
// The one test user this script logs in as (k6-loadtest@user-mgmt.local) was registered once,
// out of band -- see k6/README.md -- not created by this script, so repeated runs don't grow
// the users table.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.TARGET_URL || 'https://vcs-staging.linosteiner.ch';

const payload = JSON.stringify({
  email: 'k6-loadtest@user-mgmt.local',
  password: 'K6LoadTest123!',
});

const params = {
  headers: { 'Content-Type': 'application/json' },
};

export const options = {
  // Controlled, staged ramp: idle baseline -> moderate -> peak -> back to idle, 6 minutes
  // total. The scale-down is NOT part of the run: the HPA waits out its 5-minute scale-down
  // stabilization window (see charts/user-mgmt values) after the load drops, so it happens
  // about 5 minutes after this script ends -- watch the HPA past the Job's completion.
  stages: [
    { duration: '1m', target: 5 },   // baseline
    { duration: '1m', target: 5 },   // hold baseline
    { duration: '1m', target: 20 },  // ramp to peak
    { duration: '2m', target: 20 },  // hold peak -- this is what should push the HPA to scale
    { duration: '1m', target: 0 },   // ramp down
  ],
  thresholds: {
    // Availability check baked into the run itself: if the error rate crosses 5% at any
    // point (including during a scaling event), the test run itself reports a failed
    // threshold -- this is the automated half of "bleibt verfügbar", not just eyeballing it.
    http_req_failed: ['rate<0.05'],
  },
};

export default function () {
  const res = http.post(`${BASE_URL}/api/users/login`, payload, params);
  check(res, {
    'status is 200': (r) => r.status === 200,
    'issued a bearer token': (r) => (r.headers['Authorization'] || '').startsWith('Bearer '),
  });
  sleep(1);
}
