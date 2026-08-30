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
