// Aufgabe 6: load on the module_service through the path a real client takes -- public
// Ingress -> user_mgmt_service -> module_service -> managed MySQL. The module_service has no
// Ingress of its own and its NetworkPolicy only admits the backend, so there is no shortcut.
//
// Every iteration is one authenticated call to the backend's module endpoints:
//   70% GET /api/users/{id}/modules            -> 1 call to the module_service
//   30% PUT /api/users/{id}/modules/{moduleId} -> 2 calls (check availability, then assign)
// The PUT is idempotent (the assignment exists after the first call), so repeated runs don't
// grow the database. It uses the same pre-registered test user as login-load-test.js
// (k6/README.md) and logs in once in setup(), not per iteration: bcrypt would otherwise make
// this a login test again.
import http from 'k6/http';
import { check, fail, sleep } from 'k6';

const BASE_URL = __ENV.TARGET_URL || 'https://vcs-staging.linosteiner.ch';

// Seeded by the module_service's schema.sql.
const MODULES = [
  'c02f58f2-3aca-4f1e-8076-bacf6f1999e6', // CLOUD-ARCH
  '6d5889ee-f4c7-44d7-a887-da92d2a51ac4', // DATABASES
  '674ca4e0-6334-4b12-aa83-d97895049b8a', // SECURITY
  '4b9ff45a-d90f-42b0-8b72-20f0b92b6027', // WEB-DEV
];

export const options = {
  // baseline -> moderate -> peak -> idle, 7 minutes. The peak is what the module_service's
  // cpu/memory limits are sized against: watch "module_service - Application Metrics",
  // row Resources, during the hold.
  stages: [
    { duration: '1m', target: 5 },
    { duration: '1m', target: 20 },
    { duration: '1m', target: 40 },
    { duration: '3m', target: 40 },
    { duration: '1m', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
  },
};

export function setup() {
  const login = http.post(
    `${BASE_URL}/api/users/login`,
    JSON.stringify({ email: 'k6-loadtest@user-mgmt.local', password: 'K6LoadTest123!' }),
    { headers: { 'Content-Type': 'application/json' } },
  );
  const token = login.headers['Authorization'];
  if (login.status !== 200 || !token) fail(`login failed: ${login.status}`);
  const me = http.get(`${BASE_URL}/api/users/me`, { headers: { Authorization: token } });
  if (me.status !== 200) fail(`/users/me failed: ${me.status}`);
  return { token, userId: me.json('id') };
}

export default function ({ token, userId }) {
  const params = { headers: { Authorization: token } };
  if (Math.random() < 0.7) {
    const res = http.get(`${BASE_URL}/api/users/${userId}/modules`, {
      ...params,
      tags: { name: 'GET /api/users/{id}/modules' },
    });
    check(res, { 'list: 200': (r) => r.status === 200 });
  } else {
    const moduleId = MODULES[Math.floor(Math.random() * MODULES.length)];
    const res = http.put(`${BASE_URL}/api/users/${userId}/modules/${moduleId}`, null, {
      ...params,
      tags: { name: 'PUT /api/users/{id}/modules/{moduleId}' },
    });
    check(res, { 'assign: 200': (r) => r.status === 200 });
  }
  sleep(0.5);
}
