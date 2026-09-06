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
"repository:tag" for any of the three images. Takes the image dict itself rather than
the root context: (include "user-mgmt.image" .Values.backend.image)
*/}}
{{- define "user-mgmt.image" -}}
{{- printf "%s:%s" .repository .tag }}
{{- end }}

{{/*
Base url the frontend's server-side route handlers use to reach the backend from inside
the cluster. Release-prefixed, so each environment resolves to its own backend Service --
that is what keeps staging's logins out of prod's database.

Deliberately not a public url: the in-cluster call skips the trip out through the
LoadBalancer and back in, and the NetworkPolicy already allows frontend -> backend.
*/}}
{{- define "user-mgmt.backend.internalUrl" -}}
{{- printf "http://%s:%v%s" (include "user-mgmt.componentName" (dict "ctx" . "component" "backend")) .Values.backend.service.port .Values.backend.config.contextPath }}
{{- end }}

{{/*
PodDisruptionBudget for one component (Aufgabe 6). One definition serves backend and
frontend: (dict "ctx" $ "component" "backend").

A PDB caps how many pods may be taken away by VOLUNTARY disruption -- a node drain, a
re-schedule -- and has no say over a crash or an OOM kill. The two ways to express it are
not interchangeable:

  minAvailable   "keep at least N serving". Correct when several replicas run, but on a
                 single-replica Deployment minAvailable: 1 blocks every eviction forever
                 and a drain hangs instead of finishing.
  maxUnavailable "allow at most N to go at once". Correct for a single replica, because
                 the drain can still proceed.

Setting both is a contradiction and Kubernetes rejects it; setting neither renders a PDB
that guards nothing. Both are caught here, at template time, rather than in the cluster.
*/}}
{{- define "user-mgmt.podDisruptionBudget" -}}
{{- $cfg := (index .ctx.Values .component).podDisruptionBudget -}}
{{- if $cfg.enabled -}}
{{- $hasMin := hasKey $cfg "minAvailable" -}}
{{- $hasMax := hasKey $cfg "maxUnavailable" -}}
{{- if and $hasMin $hasMax -}}
{{- fail (printf "%s.podDisruptionBudget: set either minAvailable or maxUnavailable, not both" .component) -}}
{{- end -}}
{{- if not (or $hasMin $hasMax) -}}
{{- fail (printf "%s.podDisruptionBudget: enabled requires one of minAvailable or maxUnavailable" .component) -}}
{{- end -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "user-mgmt.componentName" . }}-pdb
  labels:
    {{- include "user-mgmt.labels" . | nindent 4 }}
spec:
  # Must be THIS component's selector labels -- a PDB that selects nothing is silently
  # accepted by the API server and protects nothing.
  selector:
    matchLabels:
      {{- include "user-mgmt.selectorLabels" . | nindent 6 }}
  {{- if $hasMin }}
  minAvailable: {{ $cfg.minAvailable }}
  {{- else }}
  maxUnavailable: {{ $cfg.maxUnavailable }}
  {{- end }}
{{- end -}}
{{- end }}

{{/*
Kills the hardcoded jdbc:postgresql://postgres:5432/ in the original manifest.
$(POSTGRES_DB) is left literal ON PURPOSE -- Kubernetes expands it, not Helm.
*/}}
{{- define "user-mgmt.postgres.jdbcUrl" -}}
{{- printf "jdbc:postgresql://%s:%v/$(POSTGRES_DB)" (include "user-mgmt.componentName" (dict "ctx" . "component" "postgres")) .Values.postgres.service.port }}
{{- end }}
