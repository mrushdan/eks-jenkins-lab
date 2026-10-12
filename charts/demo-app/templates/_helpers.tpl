{{/* Resource name: the release name, so `helm upgrade --install demo-app` keeps names stable. */}}
{{- define "demo-app.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels that select pods. Never change these on a live release: Deployment selectors are immutable. */}}
{{- define "demo-app.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Full label set for every resource. */}}
{{- define "demo-app.labels" -}}
{{ include "demo-app.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Image reference. Fails the render with a clear message if the pipeline forgot to set it. */}}
{{- define "demo-app.image" -}}
{{- $repo := required "image.repository is required (set by the pipeline)" .Values.image.repository -}}
{{- $tag := required "image.tag is required (set by the pipeline)" .Values.image.tag -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
