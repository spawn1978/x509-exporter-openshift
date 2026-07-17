#!/usr/bin/env bash
# Script de verificacion rapida del stack

NAMESPACE_EXPORTER="exportador-certificado"
NAMESPACE_GRAFANA="grafana-custom"

echo "=== Pods del exporter ==="
oc get pods -n "$NAMESPACE_EXPORTER"

echo ""
echo "=== ServiceMonitor ==="
oc get servicemonitor -n "$NAMESPACE_EXPORTER" -o wide

echo ""
echo "=== User Workload Monitoring pods ==="
oc get pods -n openshift-user-workload-monitoring

echo ""
echo "=== Pods de Grafana ==="
oc get pods -n "$NAMESPACE_GRAFANA"

echo ""
echo "=== Metricas disponibles (requiere port-forward activo en :9090) ==="
curl -s "http://localhost:9090/api/v1/query?query=x509_cert_not_after" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(f'Certificados encontrados: {len(r[\"data\"][\"result\"])}')" \
  2>/dev/null || echo "    Port-forward no activo. Ejecuta primero:"
echo "    oc port-forward svc/prometheus-user-workload 9090:9090 -n openshift-user-workload-monitoring"
