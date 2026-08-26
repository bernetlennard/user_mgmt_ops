# Phase 1 — Learn Helm, hands-on

This is the step-by-step expansion of **Phase 1** in
[`k8s/helm-todos.md`](../../../linosteiner/user_mgmt_service/k8s/helm-todos.md) (in the app repo,
`linosteiner/user_mgmt_service`). That file is the *plan*; this file is the *instructions*.

Read it top to bottom with a terminal open. Every command here was run against your actual
cluster and your actual Helm version before it was written down, so the outputs quoted are the
outputs you will get.

**Time:** ~half a day. **Risk:** none — nothing in this phase installs, upgrades or deletes
anything in the cluster. Installing is Phase 3.

**Prerequisites already satisfied:** Helm **v4.1.4**, `kubectl` pointed at context
`do-fra1-k8s-user-mgmt`, and this repo cloned at
`C:\development\git\bernetlennard\user_mgmt_ops`.

---

## Table of contents

- [0. Where you are right now](#0-where-you-are-right-now)
- [1. The one idea, and the vocabulary](#1-the-one-idea-and-the-vocabulary)
- [2. Step 1 — read the release you already have](#2-step-1--read-the-release-you-already-have)
- [3. Step 2 — the sandbox](#3-step-2--the-sandbox)
- [4. Step 3 — the five constructs, on your own YAML](#4-step-3--the-five-constructs-on-your-own-yaml)
- [5. Step 4 — the whitespace lab](#5-step-4--the-whitespace-lab)
- [6. Step 5 — build the real chart](#6-step-5--build-the-real-chart)
- [7. The verification loop](#7-the-verification-loop)
- [8. Gotchas](#8-gotchas)
- [9. Windows / PowerShell](#9-windows--powershell)
- [10. Done-checklist and cheatsheet](#10-done-checklist-and-cheatsheet)

---

## 0. Where you are right now

Phase 0 of the plan is further along than `helm-todos.md` records. Verified against the live
cluster:

| Phase 0 item | Status |
|---|---|
| 0.1 Ops repo | **Done** — this repo, cloned and empty |
| 0.2 Node resize | **Done** — node `pool-elotdt1ie-3m1xgz` is 2 vCPU / 4 GB, memory ~58% |
| 0.3 metrics-server | **Done** — installed *as a Helm release*; `kubectl top nodes` answers |
| 0.4 `NEXT_PUBLIC_API_URL` → `/api` | **Open** |
| JWT secret rotation | **Open** |

The two open items are **not blockers for Phase 1** — you are only rendering YAML here, never
applying it. They *are* blockers for Phase 3, which installs the chart onto a second hostname.
Leave them; come back to them before Phase 3.

Your four app pods (`postgres`, `user-mgmt-service`, `auth-portal`, `traefik`) keep running in
the `default` namespace, untouched, for the whole of this phase.

---

## 1. The one idea, and the vocabulary

> **Helm is a Go-template renderer plus a ledger of what it applied.**

That is genuinely all of it. Everything else is detail.

You already know how to write Kubernetes YAML — `k8s/` in the app repo proves it. Helm does not
replace that knowledge. It adds two things on top:

1. **Holes in the YAML** you fill from a config file, so one chart can produce staging *and*
   prod.
2. **A memory** of what it applied, so `helm upgrade`, `helm rollback` and `helm uninstall` know
   exactly which objects belong to which installation.

Every new word maps onto something you already do:

| Helm word | What it actually is | Your equivalent today |
|---|---|---|
| **chart** | a directory of YAML files with `{{ }}` holes in them | the `k8s/` folder |
| **values** | the file that fills the holes (`values.yaml`) | hardcoded literals in your YAML |
| **template** (verb) | fill the holes and print the result — **never touches the cluster** | reading the file |
| **release** | one installed copy of a chart, under a name | one `kubectl apply -f k8s/` |
| **revision** | a counter bumped on every `upgrade`, enabling `rollback` | you don't have one |
| **repo** | a URL serving packaged charts | Docker Hub, but for charts |

Three things — and only three — are available to you inside a template:

| Object | Contains | Example |
|---|---|---|
| `.Values` | everything from `values.yaml` and `--set` / `-f` | `.Values.backend.image.tag` |
| `.Release` | `.Name`, `.Namespace`, `.Service`, `.IsUpgrade` | `.Release.Name` |
| `.Chart` | `.Name`, `.Version`, `.AppVersion` from `Chart.yaml` | `.Chart.Version` |

(There is also `.Files` and `.Capabilities`, which you will not need.)

### The single most important distinction

| | Runs where | Runs when | Needs a cluster? |
|---|---|---|---|
| `helm template` | your laptop | now | **No** |
| `helm install` | your laptop, then the cluster | now | Yes |

`helm template` renders and prints to stdout. Nothing else. You will spend all of Phase 1 in
`helm template` and never once type `helm install`. This is why the phase is risk-free.

---

## 2. Step 1 — read the release you already have

**~10 minutes. No files created. Nothing changed.**

The gentlest way into Helm is to *consume* a chart before you author one. You already installed
one in Phase 0 (`metrics-server`), so there is a real release sitting in your cluster to poke at.

Run these in order and actually read the output:

```bash
# What releases exist, in every namespace?
helm list -A
```

```
NAME            NAMESPACE       REVISION  STATUS    CHART                   APP VERSION
metrics-server  kube-system     1         deployed  metrics-server-3.14.0   0.9.0
```

Read that row carefully — it is the whole model in one line. A **name** you chose, a
**namespace**, a **revision** counter, a **status**, and the **chart** it came from.

```bash
# What values did I supply? (You supplied none, so: empty.)
helm get values metrics-server -n kube-system

# What values were ACTUALLY used, defaults included?
helm get values metrics-server -n kube-system --all
```

The difference between those two commands is the difference between *your* config and the
chart author's defaults merged with it. That merge is what `values.yaml` is for.

```bash
# The payoff command.
helm get manifest metrics-server -n kube-system
```

Scroll through it. It is a few hundred lines of ordinary Kubernetes YAML — Deployment, Service,
ServiceAccount, ClusterRole, APIService — and there is **not a single `{{ }}` anywhere in it**.

That is the concept, complete. A release is rendered YAML that Helm wrote down. The templates
did their job at install time and are gone. Anything you can express as YAML, you can express as
a chart.

```bash
# Two more worth knowing
helm get notes   metrics-server -n kube-system    # the post-install message
helm history     metrics-server -n kube-system    # every revision, for rollback
```

**Checkpoint:** you should be able to answer — *where does the YAML in `helm get manifest` come
from, and why does it have no `{{ }}` in it?* If you can, move on.

---

## 3. Step 2 — the sandbox

**~45 minutes. Everything you create here gets deleted at the end.**

`sandbox/` is in this repo's `.gitignore`, so nothing you do here can pollute the ops repo.
Break things on purpose.

```bash
cd C:/development/git/bernetlennard/user_mgmt_ops
mkdir sandbox && cd sandbox
helm create demo
```

### 3.1 What you got

```bash
find demo -type f | sort
```

```
demo/.helmignore
demo/Chart.yaml
demo/templates/NOTES.txt
demo/templates/_helpers.tpl
demo/templates/deployment.yaml
demo/templates/hpa.yaml
demo/templates/httproute.yaml
demo/templates/ingress.yaml
demo/templates/service.yaml
demo/templates/serviceaccount.yaml
demo/templates/tests/test-connection.yaml
demo/values.yaml
```

Four rules govern that layout, and they are the entire chart file format:

| Path | Rule |
|---|---|
| `Chart.yaml` | metadata. `apiVersion: v2` (that's the *chart format* version, not Helm's) |
| `values.yaml` | the default values. Every key here becomes `.Values.<key>` |
| `templates/*.yaml` | rendered, then applied as Kubernetes objects |
| `templates/_helpers.tpl` | files starting with `_` are **not** rendered as objects — they only define reusable snippets |
| `templates/NOTES.txt` | rendered and printed after install, never applied |

> **Note:** `httproute.yaml` is new in Helm v4's scaffold (Gateway API). Most tutorials you find
> online are Helm v3 and won't show it. You're on v4.1.4 — when a tutorial's output differs from
> yours, that's usually why.

### 3.2 Render it

```bash
helm template demo ./demo
```

Note the argument order: `helm template <release-name> <chart-path>`. The release name `demo` is
invented on the spot; nothing is installed.

Count the objects that come out:

```bash
helm template demo ./demo | grep -E "^kind:"
```

```
kind: ServiceAccount
kind: Service
kind: Deployment
kind: Pod
```

**Four objects from eleven files.** Where did `hpa.yaml`, `ingress.yaml` and `httproute.yaml`
go? Open `demo/templates/hpa.yaml` — line 1 is:

```gotemplate
{{- if .Values.autoscaling.enabled }}
```

and `autoscaling.enabled` is `false` in `values.yaml`. **A template wrapped in a false condition
produces nothing at all.** This is exactly the mechanism `helm-todos.md` wants you to use for
Aufgabe 6: ship the HPA now, disabled, and enabling it later is a values change instead of a
chart change.

### 3.3 Values come from several places — last one wins

Three ways to set the same thing. Run all three and diff the output.

```bash
# 1. Edit the file
#    open demo/values.yaml, change replicaCount: 1  ->  replicaCount: 3
helm template demo ./demo | grep replicas

# 2. Override on the command line
helm template demo ./demo --set replicaCount=5 | grep replicas

# 3. Override from another file  <-- this is the Aufgabe 5 mechanism
echo "replicaCount: 7" > my-values.yaml
helm template demo ./demo -f my-values.yaml | grep replicas
```

Precedence, lowest to highest: `values.yaml` → `-f file` (left to right) → `--set`.

Method 3 is worth dwelling on. `values-staging.yaml` and `values-prod.yaml` in Aufgabe 5 are
*exactly* this: the same chart, two small override files. You have just done Aufgabe 5's core
mechanic in one line.

### 3.4 See the computed values

```bash
helm install demo ./demo --dry-run=client --debug --set replicaCount=3
```

Look for the `USER-SUPPLIED VALUES:` and `COMPUTED VALUES:` blocks above the YAML. That is the
merged result Helm will template against — invaluable when a value isn't taking effect and you
can't see why.

> **Two v4 gotchas here**, both of which will confuse you against older tutorials:
> - `helm template --debug` does **not** print computed values in v4. It prints structured
>   `level=DEBUG msg=...` log lines instead. Only `helm install --dry-run --debug` shows the
>   values blocks.
> - Bare `--dry-run` is deprecated in v4 and prints a warning. Write `--dry-run=client`.
>
> `--dry-run=client` does not install anything. It renders locally and reports what *would*
> happen.

### 3.5 Break it on purpose

This is the highest-value ten minutes in the whole phase. You will meet all of these errors for
real later; meeting them now, when you know exactly what you did, means you'll recognise them
instantly.

**Break A — a value that doesn't exist.** In `demo/templates/deployment.yaml`, change
`{{ .Values.replicaCount }}` to `{{ .Values.foo.bar }}`:

```
Error: demo/templates/deployment.yaml:9:22
  executing "demo/templates/deployment.yaml" at <.Values.foo.bar>:
    nil pointer evaluating interface {}.bar
```

*Reads as:* file, line, column, and the exact expression that failed. `nil pointer evaluating`
always means **you asked for a key that isn't in values.yaml** — usually a typo or a missing
parent key. Restore it.

**Break B — an unclosed block.** Create `demo/templates/broken.yaml`:

```gotemplate
apiVersion: v1
kind: ConfigMap
metadata:
  name: broken
{{- if .Values.replicaCount }}
data:
  x: "y"
```

```
Error: parse error at (demo/templates/broken.yaml:8): unexpected EOF
```

*Reads as:* you opened `{{- if }}` and never wrote `{{- end }}`. Note the line number is the
**end of the file**, not the `if` — so when you see `unexpected EOF`, go looking for an unclosed
`if` or `range`, not for a problem on line 8.

**Break C — the one that produces no error at all.** Change `broken.yaml` to:

```gotemplate
data:
  x: {{ toYaml .Values.resources | indent 4 }}
```

```yaml
data:
  x:     {}
```

No error. Just silently wrong YAML. **This is the dangerous class of bug** — see
[the whitespace lab](#5-step-4--the-whitespace-lab).

Delete `broken.yaml` when you're done.

### 3.6 Read the generated `_helpers.tpl`

```bash
cat demo/templates/_helpers.tpl
```

This file is the canonical example of what Aufgabe 2's `_helpers.tpl` criterion is asking for.
Two constructs:

```gotemplate
{{- define "demo.name" -}}              {{/* declare a named snippet   */}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}
```

```gotemplate
{{ include "demo.labels" . | nindent 4 }}    {{/* call it, indent the result */}}
```

The `.` in `include "demo.labels" .` is the argument. Helpers don't inherit scope — whatever you
pass as that second argument becomes `.` inside the helper. Passing `.` passes everything
(`.Values`, `.Release`, `.Chart`). You will need to pass something more interesting in
[step 5](#65-step-5--the-backend-and-_helperstpl).

> Read `_helpers.tpl` and `values.yaml`. **Then throw the rest away.** The generated
> `deployment.yaml` is written to cover every possible option and is more confusing than
> instructive.

### 3.7 Lint

```bash
helm lint ./demo
helm lint ./demo --strict
```

```
==> Linting ./demo
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

> `helm-todos.md` says `--strict` turns "chart has no icon" into an error. **That was true in
> Helm v3; it is not true in v4.1.4** — the icon notice is `[INFO]` and `--strict` still exits 0.
> Run `--strict` anyway (it does catch other things), but don't expect it to fail on the icon.

`helm lint` is the acceptance criterion for Aufgabe 2. Note what it does *not* do: it checks the
chart is well-formed and renders, not that the resulting Kubernetes objects are valid. That's
what [§7](#7-the-verification-loop) is for.

### 3.8 Clean up

```bash
cd C:/development/git/bernetlennard/user_mgmt_ops
rm -rf sandbox
```

**Checkpoint:** you should now be able to say what `values.yaml`, `templates/`, `_helpers.tpl`
and `Chart.yaml` each do, and recognise a `nil pointer` error on sight.

---

## 4. Step 3 — the five constructs, on your own YAML

Five constructs cover ~95% of every real chart. Here is each one applied to a line from your
*actual* `k8s/` manifests, so you can see precisely what Phase 5 will ask you to do.

### 1. Substitute

```yaml
# k8s/postgres/postgres-deployment.yaml
image: postgres:16-alpine
```
```gotemplate
image: {{ .Values.postgres.image.repository }}:{{ .Values.postgres.image.tag }}
```

### 2. Call a helper

```yaml
# repeated in all four of your Deployments/Services
labels:
  app: postgres
```
```gotemplate
labels:
  {{- include "user-mgmt.labels" (dict "ctx" $ "component" "postgres") | nindent 2 }}
```

### 3. Conditional

```gotemplate
{{- if .Values.backend.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
...
{{- end }}
```

Nothing in `k8s/` corresponds to this yet — that's the point. The HPA gets written in Phase 1
and stays switched off until Aufgabe 6.

### 4. Loop

```yaml
# k8s/ingress/app-ingress.yaml -- the whole paths block is written out TWICE today,
# once for vcs.lennardbernet.ch and once for vcs.linosteiner.ch
rules:
  - host: vcs.lennardbernet.ch
    ...
  - host: vcs.linosteiner.ch
    ...
```
```gotemplate
rules:
  {{- range .Values.ingress.hosts }}
  - host: {{ . | quote }}
    ...
  {{- end }}
```

### 5. Splice in a whole subtree

```yaml
# k8s/user-mgmt/user-mgmt-deployment.yaml
resources:
  requests:
    cpu: 100m
    memory: 384Mi
  limits:
    memory: 700Mi
```
```gotemplate
resources:
  {{- toYaml .Values.backend.resources | nindent 12 }}
```

`toYaml` turns a values subtree back into YAML text. `nindent 12` puts it on a new line indented
12 spaces. This pair is how every arbitrary-shaped block (resources, probes, annotations,
nodeSelector, tolerations) gets templated.

---

## 5. Step 4 — the whitespace lab

Read this section even though it looks fussy. **Indentation is the number one source of lost
hours in Helm**, because the failure mode is often silently-wrong YAML rather than an error.

### The two mechanisms

**`{{-` and `-}}` trim whitespace.** `{{-` deletes whitespace *before* the tag, including the
preceding newline. `-}}` deletes whitespace *after* it. Without them, a line containing only
`{{- if ... }}` would leave a blank line in your output.

**`indent N` vs `nindent N`.** Both indent every line of a block by N spaces. `nindent` also
prepends a newline first. That difference is everything:

| You write | Renders as | Verdict |
|---|---|---|
| `x: {{ toYaml .Values.r \| indent 4 }}` | `x:     {}` — first line glued to the key | broken |
| `x:`<br>`  {{- toYaml .Values.r \| nindent 4 }}` | key on its own line, block below it | correct |

### The rule that makes it automatic

> When splicing a **block** onto its own line, always write the key, then a newline, then
> `{{- toYaml ... | nindent N }}` — where N is the indentation the block's contents need.

The `{{-` is required: it eats the newline you just typed, and `nindent` puts back exactly one.
Without it you get two newlines and a stray blank line.

### The lab

Make a scratch chart and render the same block four ways:

```bash
mkdir -p sandbox/lab/templates && cd sandbox/lab
printf 'apiVersion: v2\nname: lab\nversion: 0.1.0\n' > Chart.yaml
cat > values.yaml <<'EOF'
resources:
  requests:
    cpu: 100m
    memory: 384Mi
  limits:
    memory: 700Mi
EOF
cat > templates/t.yaml <<'EOF'
--- A - no filter
a:
  {{ toYaml .Values.resources }}
--- B - indent
b:
  {{ toYaml .Values.resources | indent 2 }}
--- C - nindent, no dash
c:
  {{ toYaml .Values.resources | nindent 2 }}
--- D - nindent with dash  (the correct one)
d:
  {{- toYaml .Values.resources | nindent 2 }}
EOF
helm template lab . --debug 2>&1 | grep -v "^level="
```

`--debug` is **required** here. Without it you get only:

```
Error: YAML parse error on lab/templates/t.yaml: error converting YAML to JSON:
  yaml: line 2: mapping values are not allowed in this context
```

...because case A produces YAML so broken it can't be parsed. That's lesson zero:
**`--debug` prints the invalid YAML so you can see what you actually generated.** Reach for it
every time you get a "YAML parse error" — otherwise you're debugging blind.

The four cases, exactly as they render:

```yaml
--- A - no filter
a:
  limits:              # <- indented 2 (from the template), because the FIRST line
  memory: 700Mi        # <- ...but every line after it has lost its indentation
requests:              # <- now at column 0. The structure is destroyed.
  cpu: 100m
  memory: 384Mi
--- B - indent
b:
    limits:            # <- 4 spaces: 2 from the template + 2 from `indent 2`
    memory: 700Mi      # <- 4 too, so `memory` is now a SIBLING of `limits`, not a child
  requests:            # <- 2. Renders without error, means something completely different.
    cpu: 100m
    memory: 384Mi
--- C - nindent, no dash
c:
                       # <- stray whitespace-only line: your newline plus nindent's newline
  limits:
    memory: 700Mi
  requests:
    cpu: 100m
    memory: 384Mi
--- D - nindent with dash  (the correct one)
d:
  limits:
    memory: 700Mi
  requests:
    cpu: 100m
    memory: 384Mi
```

**B is the one to be afraid of.** A crashes loudly and C is merely ugly, but B renders cleanly,
lints cleanly, and silently gives your container the wrong resource limits. Five minutes here
saves an afternoon later.

Then `cd ../.. && rm -rf sandbox`.

---

## 6. Step 5 — build the real chart

Now the real work. You are going to convert `k8s/` into `charts/user-mgmt/`, **one file at a
time, easiest first, learning exactly one new construct per file.**

You are in an unusually good position: you already have known-good YAML. So you never have to
*wonder* whether a template is right — you render it and compare.

> **Do not start with `_helpers.tpl`.** Copy-paste the label block the first four times and let
> it annoy you. Refactoring it into a helper at step 5.5 is when `define`/`include` stops being
> abstract. This is deliberate; resist the urge to be clever early.

### 6.0 Scaffold

```bash
cd C:/development/git/bernetlennard/user_mgmt_ops
mkdir charts && cd charts
helm create user-mgmt
rm -rf user-mgmt/templates/*
mkdir -p user-mgmt/templates/postgres user-mgmt/templates/backend user-mgmt/templates/frontend
```

Keep the generated `Chart.yaml` and `.helmignore`; empty `values.yaml`:

```bash
echo "" > user-mgmt/values.yaml
```

Edit `Chart.yaml` — set a real description and add an `icon:` line (free `helm lint` cleanliness):

```yaml
apiVersion: v2
name: user-mgmt
description: User management stack - Spring Boot backend, Next.js frontend, PostgreSQL
type: application
version: 0.1.0
appVersion: "1.0.0"
icon: https://helm.sh/img/helm.svg
```

Every command below is run from `charts/` (so `./user-mgmt` is the chart path).

---

### 6.1 `postgres/configmap.yaml` — plain substitution

**Source:** [`k8s/postgres/postgres-config.yaml`](../../../linosteiner/user_mgmt_service/k8s/postgres/postgres-config.yaml)

Add to `values.yaml`:

```yaml
postgres:
  database: user_mgmt_db
```

Create `templates/postgres/configmap.yaml`:

```gotemplate
apiVersion: v1
kind: ConfigMap
metadata:
  # HARDCODED FOR NOW -- fixed in step 6.3 when you learn .Release.Name.
  name: postgres-config
data:
  POSTGRES_DB: {{ .Values.postgres.database | quote }}
```

**Self-check:**

```bash
helm template um ./user-mgmt -s templates/postgres/configmap.yaml
```

`-s` renders exactly one template instead of the whole chart. It is the single biggest
time-saver in this phase and it is not mentioned in `helm-todos.md`. The path is relative to the
chart root and must be exact — `-s postgres/configmap.yaml` gives
`Error: could not find template ... in chart`.

Compare against the original. Ignore the comments (Helm strips `{{/* */}}` comments but keeps
`#` YAML comments — the originals in `k8s/` are heavily commented and yours won't be). The
`data:` block must match exactly.

---

### 6.2 `postgres/secret.yaml` — `quote`, and `stringData`

**Source:** [`k8s/postgres/postgres-secret.yaml`](../../../linosteiner/user_mgmt_service/k8s/postgres/postgres-secret.yaml)

Add to `values.yaml` under `postgres:`:

```yaml
postgres:
  database: user_mgmt_db
  auth:
    username: admin
    password: admin
```

Create `templates/postgres/secret.yaml`:

```gotemplate
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret     # still hardcoded, still fixed in 6.3
type: Opaque
# stringData, not data: Kubernetes base64-encodes these for us. With `data:` you would
# have to write {{ .Values.postgres.auth.password | b64enc }} and every debugging session
# would start with base64 -d.
stringData:
  POSTGRES_USER: {{ .Values.postgres.auth.username | quote }}
  POSTGRES_PASSWORD: {{ .Values.postgres.auth.password | quote }}
```

**Why `| quote` and not just `{{ .Values... }}`?** Because YAML will happily reinterpret an
unquoted value. A password of `123456` becomes the *integer* 123456 and Kubernetes rejects the
Secret; a value of `NO` becomes the boolean `false`. `| quote` makes the type unambiguous.
**Habit worth forming: quote every value that is conceptually a string.**

> Same caveat as the original file: this commits credentials to git. The ops repo is private and
> `helm-todos.md` accepts the tradeoff for now — but say so explicitly in the final README, the
> way `k8s/postgres/postgres-secret.yaml` already does. Sealed Secrets is the real answer.

---

### 6.3 `postgres/service.yaml` — `.Release.Name` and the label contract

**Source:** [`k8s/postgres/postgres-service.yaml`](../../../linosteiner/user_mgmt_service/k8s/postgres/postgres-service.yaml)

This is the step where names stop being hardcoded — which is the entire point of Aufgabe 2's
*"warum kein Hardcoding"* criterion.

Create `templates/postgres/service.yaml`:

```gotemplate
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-postgres
  labels:
    app.kubernetes.io/name: user-mgmt
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: postgres
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: user-mgmt
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
```

Now **go back and fix 6.1 and 6.2** to use `{{ .Release.Name }}-postgres` as their name too.
Feel that edit — it's the first taste of the repetition that `_helpers.tpl` exists to remove.

#### The label contract — read this twice

There are **two** label blocks above and they are not the same thing:

- `metadata.labels` — descriptive. Add to them freely at any time.
- `spec.selector` — **functional and immutable**. It is what wires this Service to those pods.
  Kubernetes will not let you change a Deployment's `spec.selector` after install: `helm upgrade`
  fails outright with a message about an immutable field.

So: **decide your selector labels now and never touch them again.** Three keys —
`name`, `instance`, `component` — is the standard and is what you'll use everywhere.

`component` is what lets one chart contain three different workloads: `postgres`, `backend` and
`frontend` all share `name` and `instance` but differ on `component`, so each Service selects
exactly its own pods.

**Self-check — the whole reason for this step:**

```bash
helm template a ./user-mgmt -s templates/postgres/service.yaml
helm template b ./user-mgmt -s templates/postgres/service.yaml
```

Two different release names produce two differently-named Services with no collision. That is
the property Aufgabe 5 depends on.

---

### 6.4 `postgres/deployment.yaml` + `pvc.yaml` — `toYaml | nindent`

**Source:** [`k8s/postgres/postgres-deployment.yaml`](../../../linosteiner/user_mgmt_service/k8s/postgres/postgres-deployment.yaml), [`k8s/postgres/postgres-pvc.yaml`](../../../linosteiner/user_mgmt_service/k8s/postgres/postgres-pvc.yaml)

Add to `values.yaml` under `postgres:`:

```yaml
postgres:
  image:
    repository: postgres
    tag: "16-alpine"
    pullPolicy: IfNotPresent
  persistence:
    enabled: true
    size: 1Gi
    accessMode: ReadWriteOnce
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 256Mi
  probes:
    readiness:
      exec:
        command: ["sh", "-c", 'exec pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"']
      initialDelaySeconds: 5
      periodSeconds: 10
    liveness:
      exec:
        command: ["sh", "-c", 'exec pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"']
      initialDelaySeconds: 15
      periodSeconds: 20
```

`templates/postgres/pvc.yaml`:

```gotemplate
{{- if .Values.postgres.persistence.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Release.Name }}-postgres
  labels:
    app.kubernetes.io/name: user-mgmt
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: postgres
spec:
  accessModes:
    - {{ .Values.postgres.persistence.accessMode }}
  resources:
    requests:
      storage: {{ .Values.postgres.persistence.size }}
{{- end }}
```

`templates/postgres/deployment.yaml`:

```gotemplate
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-postgres
  labels:
    app.kubernetes.io/name: user-mgmt
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: postgres
spec:
  replicas: 1
  # Recreate, not RollingUpdate: the PVC is ReadWriteOnce, so two Postgres pods can
  # never hold the data volume at once. Not a value -- it is structurally required.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: user-mgmt
      app.kubernetes.io/instance: {{ .Release.Name }}
      app.kubernetes.io/component: postgres
  template:
    metadata:
      labels:
        app.kubernetes.io/name: user-mgmt
        app.kubernetes.io/instance: {{ .Release.Name }}
        app.kubernetes.io/component: postgres
    spec:
      containers:
        - name: postgres
          image: "{{ .Values.postgres.image.repository }}:{{ .Values.postgres.image.tag }}"
          imagePullPolicy: {{ .Values.postgres.image.pullPolicy }}
          ports:
            - containerPort: 5432
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          envFrom:
            - secretRef:
                name: {{ .Release.Name }}-postgres
            - configMapRef:
                name: {{ .Release.Name }}-postgres
          volumeMounts:
            - name: postgres-storage
              mountPath: /var/lib/postgresql/data
          resources:
            {{- toYaml .Values.postgres.resources | nindent 12 }}
          readinessProbe:
            {{- toYaml .Values.postgres.probes.readiness | nindent 12 }}
          livenessProbe:
            {{- toYaml .Values.postgres.probes.liveness | nindent 12 }}
      volumes:
        - name: postgres-storage
          persistentVolumeClaim:
            claimName: {{ .Release.Name }}-postgres
```

Count how many times you just typed the same four label lines. **Five.** Hold that thought.

**Self-check:**

```bash
helm template um ./user-mgmt -s templates/postgres/deployment.yaml
```

Render it and read the probe output carefully:

```yaml
          readinessProbe:
            exec:
              command:
              - sh
              - -c
              - exec pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
```

`toYaml` rewrote the JSON-style array `["sh", "-c", ...]` as a YAML block sequence. **That is the
same value** — YAML has two syntaxes for a list. Don't panic when the rendered output doesn't
look character-identical to the original; what matters is that it *means* the same thing.

Note also that `$POSTGRES_USER` survived intact. Helm doesn't touch `$` — only `{{ }}`.

---

### 6.5 Step 5 — the backend, and `_helpers.tpl`

**Source:** [`k8s/user-mgmt/`](../../../linosteiner/user_mgmt_service/k8s/user-mgmt/) (config, secret, deployment, service)

You have now copy-pasted that label block five times. **Now** refactor it — this is the moment
`define`/`include` becomes obvious rather than abstract.

#### The helper file

Create `templates/_helpers.tpl`:

```gotemplate
{{/*
Chart name, overridable. Used as app.kubernetes.io/name.
*/}}
{{- define "user-mgmt.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Release-prefixed base name. Everything the chart creates is named from this,
which is what makes two installs in two namespaces collision-free.
*/}}
{{- define "user-mgmt.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Name for one component: <release>-<chart>-postgres, -backend, -frontend.
Takes a dict: (dict "ctx" $ "component" "postgres")
*/}}
{{- define "user-mgmt.componentName" -}}
{{- printf "%s-%s" (include "user-mgmt.fullname" .ctx) .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
IMMUTABLE. These three keys go into spec.selector and can never change after install.
Takes a dict: (dict "ctx" $ "component" "backend")
*/}}
{{- define "user-mgmt.selectorLabels" -}}
app.kubernetes.io/name: {{ include "user-mgmt.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Full descriptive label set: the selector labels plus metadata. Safe to extend.
*/}}
{{- define "user-mgmt.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .ctx.Chart.Name .ctx.Chart.Version | replace "+" "_" }}
{{ include "user-mgmt.selectorLabels" . }}
{{- if .ctx.Chart.AppVersion }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
{{- end }}

{{/*
Kills the hardcoded jdbc:postgresql://postgres:5432/ in the original manifest.
$(POSTGRES_DB) is left literal ON PURPOSE -- Kubernetes expands it, not Helm.
*/}}
{{- define "user-mgmt.postgres.jdbcUrl" -}}
{{- printf "jdbc:postgresql://%s:5432/$(POSTGRES_DB)" (include "user-mgmt.componentName" (dict "ctx" . "component" "postgres")) }}
{{- end }}
```

#### Why `dict`, and what `$` is

A helper does not inherit your scope. Whatever you pass as the second argument to `include`
becomes `.` inside the helper. Passing plain `.` gives the helper access to `.Values` and
`.Release` — but no way to say *which component* you want labels for.

So you pass a two-key dictionary instead:

```gotemplate
{{- include "user-mgmt.labels" (dict "ctx" $ "component" "backend") | nindent 4 }}
```

Inside the helper, `.ctx` is the whole context (hence `.ctx.Release.Name`, not `.Release.Name`)
and `.component` is the string. **This is what makes the helper genuinely reusable across three
components rather than a token one** — exactly what the Aufgabe 2 criterion is after.

`$` always means the root context, no matter how deeply nested you are. Inside `range`, `.` is
rebound to the current element and `.Values` breaks — `$` never does. **Use `$` rather than `.`
in every `dict "ctx"` and you can never get this wrong.**

#### Now rewrite steps 6.1–6.4

Replace every hardcoded name and every pasted label block:

```gotemplate
metadata:
  name: {{ include "user-mgmt.componentName" (dict "ctx" $ "component" "postgres") }}
  labels:
    {{- include "user-mgmt.labels" (dict "ctx" $ "component" "postgres") | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- include "user-mgmt.selectorLabels" (dict "ctx" $ "component" "postgres") | nindent 6 }}
```

Watch the `nindent` numbers — they differ by nesting depth (4 under `metadata`, 6 under
`matchLabels`). Getting them wrong is the most common mistake in this whole step.

**Self-check before continuing:**

```bash
helm template um ./user-mgmt | grep -c "app.kubernetes.io/component: postgres"
```

Same count as before the refactor, and `helm lint ./user-mgmt` still clean.

#### Backend config, secret and service

Add to `values.yaml`:

```yaml
backend:
  image:
    repository: xxpirl2knc5/user_mgmt_service
    tag: latest              # <-- Aufgabe 4's pipeline rewrites exactly this line
    pullPolicy: Always
  replicaCount: 1
  strategy:
    type: Recreate           # <-- becomes RollingUpdate in Aufgabe 6
  service:
    port: 8080
  config:
    jwtIssuer: user-mgmt-service
    jwtExpirationMillis: 3600000
    ddlAuto: update
    contextPath: /api
    javaToolOptions: "-XX:MaxRAMPercentage=60"
  jwtSecret: "CHANGE-ME-generate-a-fresh-key"
  resources:
    requests:
      cpu: 100m
      memory: 384Mi
    limits:
      memory: 700Mi
  probes:
    readiness:
      tcpSocket: { port: 8080 }
      initialDelaySeconds: 20
      periodSeconds: 5
      failureThreshold: 6
    liveness:
      tcpSocket: { port: 8080 }
      initialDelaySeconds: 60
      periodSeconds: 20
      failureThreshold: 3
  autoscaling:              # <-- Aufgabe 6, shipped disabled
    enabled: false
    minReplicas: 1
    maxReplicas: 4
    targetCPUUtilizationPercentage: 70
  podDisruptionBudget:      # <-- Aufgabe 6, shipped disabled
    enabled: false
    minAvailable: 1
```

> **`jwtExpirationMillis: 3600000` is the trap** `helm-todos.md` warns about. It is a number in
> values but a ConfigMap `data:` value must be a **string**. `| quote` in the template. See
> [§8](#8-gotchas) for what happens if you forget — it is worse than you'd expect.

`templates/backend/configmap.yaml`:

```gotemplate
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "user-mgmt.componentName" (dict "ctx" $ "component" "backend") }}
  labels:
    {{- include "user-mgmt.labels" (dict "ctx" $ "component" "backend") | nindent 4 }}
data:
  JWT_ISSUER: {{ .Values.backend.config.jwtIssuer | quote }}
  JWT_EXPIRATION_MILLIS: {{ .Values.backend.config.jwtExpirationMillis | quote }}
  SPRING_JPA_HIBERNATE_DDL_AUTO: {{ .Values.backend.config.ddlAuto | quote }}
  SERVER_SERVLET_CONTEXT_PATH: {{ .Values.backend.config.contextPath | quote }}
  JAVA_TOOL_OPTIONS: {{ .Values.backend.config.javaToolOptions | quote }}
```

`templates/backend/secret.yaml` and `templates/backend/service.yaml` follow the same shapes as
6.2 and 6.3 with `"component" "backend"` and port 8080. Write them yourself — if you can, you've
got it.

#### The backend Deployment — where hardcoding actually dies

The interesting lines only; the rest mirrors 6.4:

```gotemplate
spec:
  replicas: {{ .Values.backend.replicaCount }}
  strategy:
    {{- toYaml .Values.backend.strategy | nindent 4 }}
  template:
    metadata:
      annotations:
        # Change a ConfigMap value -> this hash changes -> the pod template changes
        # -> the pod restarts and picks it up. `kubectl apply` never does this.
        checksum/config: {{ include (print $.Template.BasePath "/backend/configmap.yaml") . | sha256sum }}
      labels:
        {{- include "user-mgmt.selectorLabels" (dict "ctx" $ "component" "backend") | nindent 8 }}
    spec:
      containers:
        - name: backend
          image: "{{ .Values.backend.image.repository }}:{{ .Values.backend.image.tag }}"
          imagePullPolicy: {{ .Values.backend.image.pullPolicy }}
          env:
            - name: POSTGRES_DB
              valueFrom:
                configMapKeyRef:
                  name: {{ include "user-mgmt.componentName" (dict "ctx" $ "component" "postgres") }}
                  key: POSTGRES_DB
            # THE POINT OF THE WHOLE EXERCISE.
            # Was: jdbc:postgresql://postgres:5432/$(POSTGRES_DB)
            # -- which only worked because the Service happened to be named exactly
            # `postgres`. Now that names are release-prefixed, that would break.
            - name: SPRING_DATASOURCE_URL
              value: {{ include "user-mgmt.postgres.jdbcUrl" $ | quote }}
```

The `checksum/config` annotation is worth demonstrating when you present. It is the clearest
single example of Helm earning its keep over `kubectl apply`.

**Self-check:**

```bash
helm template um ./user-mgmt -s templates/backend/deployment.yaml | grep -A1 SPRING_DATASOURCE_URL
```

```
            - name: SPRING_DATASOURCE_URL
              value: "jdbc:postgresql://um-user-mgmt-postgres:5432/$(POSTGRES_DB)"
```

Two things to confirm: the hostname is release-derived, and `$(POSTGRES_DB)` is still literal.

#### HPA and PDB — write them now, disabled

```gotemplate
{{- if .Values.backend.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
...
{{- end }}
```

They render to nothing today. Aufgabe 6 becomes a one-line values change. Verify they're
inert:

```bash
helm template um ./user-mgmt | grep -c HorizontalPodAutoscaler    # expect 0
helm template um ./user-mgmt --set backend.autoscaling.enabled=true | grep -c HorizontalPodAutoscaler
```

---

### 6.6 Step 6 — the frontend

**Source:** [`k8s/auth-portal/`](../../../linosteiner/user_mgmt_service/k8s/auth-portal/)

This step should be *fast* and slightly boring. That is the success condition — it proves the
helper from 6.5 is genuinely reusable and not a special case. Same three files with
`"component" "frontend"`, port 3000, `httpGet` probes instead of `tcpSocket`.

If you find yourself needing to *change* `_helpers.tpl` to make the frontend work, the helper
wasn't general enough — fix it now, before ingress.

---

### 6.7 Step 7 — the Ingress: `range` and `if`

**Source:** [`k8s/ingress/app-ingress.yaml`](../../../linosteiner/user_mgmt_service/k8s/ingress/app-ingress.yaml)

Add to `values.yaml`:

```yaml
ingress:
  enabled: true
  className: traefik
  hosts:
    - vcs.lennardbernet.ch
    - vcs.linosteiner.ch     # <-- per-environment in Aufgabe 5
  tls:
    enabled: true
    certResolver: letsencrypt
```

`templates/ingress.yaml`:

```gotemplate
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "user-mgmt.fullname" . }}
  labels:
    {{- include "user-mgmt.labels" (dict "ctx" $ "component" "ingress") | nindent 4 }}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    {{- if .Values.ingress.tls.enabled }}
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: {{ .Values.ingress.tls.certResolver }}
    {{- end }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  {{- if .Values.ingress.tls.enabled }}
  tls:
    - hosts:
        {{- range .Values.ingress.hosts }}
        - {{ . | quote }}
        {{- end }}
  {{- end }}
  rules:
    {{- range .Values.ingress.hosts }}
    - host: {{ . | quote }}
      http:
        paths:
          # /api and / are STRUCTURAL, not configuration -- they follow from
          # SERVER_SERVLET_CONTEXT_PATH. Keep them literal; range only over hosts.
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: {{ include "user-mgmt.componentName" (dict "ctx" $ "component" "backend") }}
                port:
                  number: {{ $.Values.backend.service.port }}
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ include "user-mgmt.componentName" (dict "ctx" $ "component" "frontend") }}
                port:
                  number: {{ $.Values.frontend.service.port }}
    {{- end }}
{{- end }}
```

**Look hard at the `$` characters inside the `range`.** Within the loop, `.` is the current
hostname string — a plain string with no `.Values` on it. `{{ .Values.backend... }}` in there
fails with `nil pointer evaluating`. `$` reaches back to the root and always works. This is the
scope gotcha from `helm-todos.md`, and this template is where it will bite you.

Also note there is **no `secretName`** under `tls:`. That's not an omission — Traefik obtains and
stores the certificate itself in `acme.json` on its PVC, so the cert is not a Kubernetes object
at all. Preserved exactly as in the original.

**Self-check:**

```bash
helm template um ./user-mgmt -s templates/ingress.yaml
```

Two `rules` entries, each with two paths, both Service names release-prefixed.

---

## 7. The verification loop

Run these constantly, not just at the end.

### Render one file

```bash
helm template um ./user-mgmt -s templates/postgres/deployment.yaml
```

### Render everything and compare against the known-good original

```bash
helm template um ./user-mgmt > /tmp/rendered.yaml
```

Compare with `k8s/`. **Names and label blocks will differ on purpose. The container spec, env
vars, ports, resources and probes must not.** If something else differs, you changed behaviour
by accident.

### Lint — the Aufgabe 2 acceptance criterion

```bash
helm lint ./user-mgmt
helm lint ./user-mgmt --strict
```

Aufgabe 2 requires no *errors*, so plain `helm lint` is the bar. Run `--strict` anyway.

### Validate against the real Kubernetes API — use `server`, not `client`

```bash
helm template um ./user-mgmt | kubectl apply --dry-run=server -f -
```

> **This is the most important correction to `helm-todos.md` in this document.** That file's
> Phase 4 uses `--dry-run=client`. Measured on your cluster:
>
> ```
> # ConfigMap with an unquoted numeric value:
> $ kubectl apply --dry-run=client -f cm.yaml
> configmap/broken-num-test created (dry run)          <-- PASSES. Bug not caught.
>
> $ kubectl apply --dry-run=server -f cm.yaml
> Error from server (BadRequest): ConfigMap in version "v1" cannot be handled as a
> ConfigMap: json: cannot unmarshal number into Go struct field ConfigMap.data of type string
> ```
>
> `--dry-run=client` does not know the Kubernetes schema. It would sail straight past exactly
> the `JWT_EXPIRATION_MILLIS` bug `helm-todos.md` warns about. **Use `--dry-run=server`** — it
> asks the real API server to validate and persists nothing. (Adding `--validate=strict` to the
> client form does *not* help; also measured.)

### Prove there is no hardcoding left

```bash
diff <(helm template a ./user-mgmt) <(helm template b ./user-mgmt)
```

**Every single difference must be a name or a label.** If a hostname, a port, a JDBC URL or a
`claimName` shows up in that diff as identical between the two — you have a hardcoded value that
will collide when Aufgabe 5 installs the chart twice.

Belt and braces:

```bash
helm template um ./user-mgmt | grep -n "postgres:5432"    # expect only the release-prefixed form
helm template um ./user-mgmt | grep -n "namespace:"       # expect nothing hardcoded
```

### Prove it works for both environments before Aufgabe 5

```bash
helm template um ./user-mgmt -f ../values-staging.yaml | kubectl apply --dry-run=server -f -
helm template um ./user-mgmt -f ../values-prod.yaml    | kubectl apply --dry-run=server -f -
```

---

## 8. Gotchas

Each of these is a real error you will hit. Listed as **symptom → cause → fix** so you can find
them by pasting the error message.

### `nil pointer evaluating interface {}.foo`

```
Error: user-mgmt/templates/backend/deployment.yaml:9:22
  executing "..." at <.Values.foo.bar>: nil pointer evaluating interface {}.bar
```

**Cause:** the key isn't in `values.yaml`. Usually a typo, or you added the template before the
value.
**Fix:** add the key. If the value is genuinely optional, guard it:
`{{- if .Values.foo }}` or `{{ .Values.foo | default "x" }}`.

### `parse error at (...): unexpected EOF`

**Cause:** an `{{- if }}` or `{{- range }}` with no `{{- end }}`. The reported line is the end of
the file, not the problem.
**Fix:** count your `end`s.

### `field is immutable` on `helm upgrade`

```
Error: UPGRADE FAILED: cannot patch "um-user-mgmt-backend" ... field is immutable
```

**Cause:** you changed `spec.selector` — usually by editing `user-mgmt.selectorLabels` after
installing.
**Fix:** there is no in-place fix. `helm uninstall` and reinstall. **This is why
[§6.3](#63-postgresserviceyaml--releasename-and-the-label-contract) tells you to settle your
selector labels before you ever install.** It's also precisely why Phase 3 installs into a new
namespace rather than upgrading in place.

### A ConfigMap value that is a number

**Symptom:** renders fine, lints fine, passes `--dry-run=client`, then fails at install with
`cannot unmarshal number into Go struct field ConfigMap.data of type string`.
**Cause:** ConfigMap and Secret `data:`/`stringData:` values must be strings. `3600000` is not.
**Fix:** `| quote`. Quote everything string-ish by default.

### `{{ }}` and `$( )` in the same file

`k8s/user-mgmt/user-mgmt-deployment.yaml:50` reads:

```yaml
value: jdbc:postgresql://postgres:5432/$(POSTGRES_DB)
```

These look similar and are completely unrelated:

| Syntax | Expanded by | When |
|---|---|---|
| `{{ .Values.x }}` | Helm, on your laptop | before the cluster ever sees the file |
| `$(POSTGRES_DB)` | Kubernetes, in the kubelet | when the container starts |

**Leave `$(POSTGRES_DB)` exactly as it is.** Helm passes `$` through untouched — verified in
[§6.5](#65-step-5--the-backend-and-_helperstpl). Turning it into `{{ }}` would break it, because
at template time Helm has no idea what the ConfigMap will contain.

Related: `$(VAR)` in a container `env:` list only resolves against variables declared **earlier
in that same list**, and **never** against `envFrom`. That's why the postgres probes use
`sh -c '... "$POSTGRES_USER"'` — a real shell, expanding a real environment variable, one layer
further down still. Three different expansion mechanisms in one file. Don't mix them up.

### `.` inside `range` is not what you think

**Symptom:** `nil pointer` on a `.Values` reference that works fine elsewhere.
**Cause:** inside `{{- range }}`, `.` is rebound to the current element.
**Fix:** use `$.Values`, or capture the root first: `{{- $root := . -}}`.

### `indent` where you meant `nindent`

**Symptom:** no error, invalid YAML.
**Fix:** see [§5](#5-step-4--the-whitespace-lab). `{{- ... | nindent N }}` on its own line.

### `helm template` doesn't talk to the cluster

`helm template` renders entirely offline — it works with no kubeconfig at all. `--dry-run=client`
also renders locally; only `--dry-run=server` and `helm install` contact the API server.

Consequence: the `lookup` function returns empty under `helm template`, and Helm guesses API
versions rather than asking your cluster. Not a problem for this chart — but it explains why a
chart can render perfectly and still fail on install.

### Output order isn't file order

Helm sorts rendered objects into a **install-safe order** (namespaces, then ConfigMaps/Secrets,
then workloads), not the order your files are in. Two objects in one file can come out swapped.
Nothing is wrong.

### `namespace:` should never be hardcoded

`k8s/traefik/traefik-rbac.yaml:64` hardcodes `namespace: default` in the ClusterRoleBinding
subject. In a chart that becomes `{{ .Release.Namespace }}` — that's Phase 5's job, but grep for
`namespace:` in your own templates now and make sure none crept in. **A chart should never set
`metadata.namespace` at all** — `helm install -n <ns>` handles it.

---

## 9. Windows / PowerShell

`helm-todos.md` is written in bash, and **several of its commands fail as written on your
machine**.

> **Recommendation: use Git Bash for this entire phase.** Every command in `helm-todos.md` and
> in this document then works verbatim. The PowerShell equivalents below are for when you don't.

| Bash form | Why it breaks in PowerShell | PowerShell form |
|---|---|---|
| `diff <(cmd1) <(cmd2)` | `<(...)` process substitution doesn't exist | render to two files, then `Compare-Object` |
| `--set ingress.hosts={a,b}` | `{}` starts a script block | single-quote the whole argument |
| `cmd > out.yaml` | works, but may add a UTF-8 BOM | `Out-File -Encoding utf8`, or prefer `-s` |
| `grep`, `find`, `rm -rf` | don't exist | `Select-String`, `Get-ChildItem`, `Remove-Item -Recurse -Force` |

**Two-release collision test in PowerShell** (verified working):

```powershell
helm template a ./user-mgmt | Out-File -Encoding utf8 $env:TEMP\a.yaml
helm template b ./user-mgmt | Out-File -Encoding utf8 $env:TEMP\b.yaml
Compare-Object (Get-Content $env:TEMP\a.yaml) (Get-Content $env:TEMP\b.yaml)
```

**`--set` with a list in PowerShell** (verified working):

```powershell
helm template um ./user-mgmt --set 'ingress.hosts={staging.vcs.lennardbernet.ch}'
```

**Note on stderr:** PowerShell 5.1 wraps a native program's stderr in a red `NativeCommandError`
block even when the command succeeded. When `helm` prints `level=WARN ...` you'll see an
alarming red wall of text — check the actual output before assuming it failed.

---

## 10. Done-checklist and cheatsheet

### Phase 1 is complete when

- [ ] You can explain, without looking: what a chart, a release, `values.yaml` and `_helpers.tpl` are
- [ ] `charts/user-mgmt` renders all 12-ish objects: `helm template um ./charts/user-mgmt`
- [ ] `helm lint ./charts/user-mgmt` reports 0 failures
- [ ] `helm template um ./charts/user-mgmt | kubectl apply --dry-run=server -f -` passes clean
- [ ] `diff <(helm template a ...) <(helm template b ...)` shows **only** names and labels
- [ ] `grep "postgres:5432"` on the rendered output finds only the release-prefixed hostname
- [ ] HPA and PDB templates exist and render to **nothing** by default
- [ ] `sandbox/` is deleted
- [ ] **Nothing has been installed.** `helm list -A` still shows only `metrics-server`

### Cheatsheet

```bash
# Explore an existing release (no risk)
helm list -A
helm get values   <rel> -n <ns> --all
helm get manifest <rel> -n <ns>
helm history      <rel> -n <ns>

# Author (all local, no cluster)
helm create <name>
helm template <rel> <chart>                          # render everything
helm template <rel> <chart> -s templates/x/y.yaml    # render ONE file  <- use constantly
helm template <rel> <chart> --set key=value
helm template <rel> <chart> -f other-values.yaml
helm lint <chart>
helm lint <chart> --strict

# Verify
helm install <rel> <chart> --dry-run=client --debug  # shows COMPUTED VALUES
helm template <rel> <chart> | kubectl apply --dry-run=server -f -

# Phase 3 and beyond -- NOT yet
helm install / upgrade / rollback / uninstall
```

### Next

Back to [`k8s/helm-todos.md`](../../../linosteiner/user_mgmt_service/k8s/helm-todos.md):

- **Phase 3** installs the chart into a `staging` namespace alongside the running stack.
  Do the two open Phase 0 items first (`NEXT_PUBLIC_API_URL` → `/api`, and rotate the JWT
  secret — it's committed in plaintext at `k8s/user-mgmt/user-mgmt-secret.yaml`).
- **Phase 5** templatizes Traefik into `charts/platform`. Last, because it's the only step that
  can cost you the public IP and the TLS certificate.
