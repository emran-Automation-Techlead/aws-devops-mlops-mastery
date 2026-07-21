{{/*
Standard labels applied to every resource this chart creates - what lets
`kubectl get pods -l app.kubernetes.io/instance=microservices` find
everything this release owns, and what Prometheus/Grafana group by.
*/}}
{{- define "microservices.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
