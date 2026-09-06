{{/*
Chart name, overridable. Used as app.kubernetes.io/name.
*/}}
{{- define "user-mgmt.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Release-prefixed base name. Everything the chart creates is named from this, so two installs
in two namespaces cannot collide.
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
Base url the frontend's server-side route handlers use to reach the backend. Release-prefixed
and in-cluster, so each environment resolves to its own backend Service and the call skips the
trip out through the LoadBalancer and back in.
*/}}
{{- define "user-mgmt.backend.internalUrl" -}}
{{- printf "http://%s:%v%s" (include "user-mgmt.componentName" (dict "ctx" . "component" "backend")) .Values.backend.service.port .Values.backend.config.contextPath }}
{{- end }}

{{/*
PodDisruptionBudget for one component: (dict "ctx" $ "component" "backend").

A PDB caps how many pods a VOLUNTARY disruption (a drain, a re-schedule) may take; it has no
say over crashes or OOM kills. Exactly one of the two forms must be set:

  minAvailable   "keep at least N serving". For several replicas. On a single-replica
                 Deployment minAvailable: 1 permits no eviction at all and a drain hangs.
  maxUnavailable "allow at most N to go at once". Correct for a single replica.

Both or neither fails here at template time rather than in the cluster.
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
  # Must be this component's selector labels: a PDB that selects nothing is accepted
  # silently and protects nothing.
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
JDBC url built from the release-prefixed Postgres Service name.
$(POSTGRES_DB) stays literal on purpose -- Kubernetes expands it, not Helm.
*/}}
{{- define "user-mgmt.postgres.jdbcUrl" -}}
{{- printf "jdbc:postgresql://%s:%v/$(POSTGRES_DB)" (include "user-mgmt.componentName" (dict "ctx" . "component" "postgres")) .Values.postgres.service.port }}
{{- end }}
