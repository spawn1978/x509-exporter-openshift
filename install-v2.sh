#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# x509-certificate-exporter en OpenShift CRC
# ============================================================

NAMESPACE_EXPORTER="exportador-certificado"
NAMESPACE_GRAFANA="grafana-custom"
SA_EXPORTER="x509-certificate-exporter"
SA_GRAFANA_DS="grafana-datasource"

# ------------------------------------------------------------
# 1. Habilitar User Workload Monitoring
# ------------------------------------------------------------
echo "==> [1/7] Habilitando User Workload Monitoring..."

if oc get configmap cluster-monitoring-config -n openshift-monitoring &>/dev/null; then
  oc patch configmap cluster-monitoring-config -n openshift-monitoring \
    --type merge -p '{"data":{"config.yaml":"enableUserWorkload: true\n"}}'
else
  oc apply -f config.yaml
fi

echo "    Esperando pods de user-workload-monitoring..."
oc rollout status deployment/prometheus-operator \
  -n openshift-user-workload-monitoring --timeout=120s

# ------------------------------------------------------------
# 2. Crear namespace del exporter
# ------------------------------------------------------------
echo "==> [2/7] Creando proyecto $NAMESPACE_EXPORTER..."
oc new-project "$NAMESPACE_EXPORTER" 2>/dev/null || \
  echo "    Proyecto ya existe, continuando..."

# ------------------------------------------------------------
# 3. Instalar x509-certificate-exporter via Helm (OCI, v4)
# ------------------------------------------------------------
echo "==> [3/7] Instalando x509-certificate-exporter (chart v4 via OCI)..."
helm upgrade --install x509-certificate-exporter \
  oci://quay.io/enix/charts/x509-certificate-exporter \
  -n "$NAMESPACE_EXPORTER" \
  -f x509-values.yaml \

echo "==> [3b/7] Eliminando runAsUser y runAsGroup del deployment..."
oc patch deployment x509-certificate-exporter \
  -n "$NAMESPACE_EXPORTER" \
  --type='json' \
  -p='[
    {"op":"remove","path":"/spec/template/spec/containers/0/securityContext/runAsUser"},
    {"op":"remove","path":"/spec/template/spec/containers/0/securityContext/runAsGroup"}
  ]'

# ------------------------------------------------------------
# 4. Configurar permisos OpenShift
# ------------------------------------------------------------
echo "==> [4/7] Configurando SCC nonroot para el exporter..."
oc adm policy add-scc-to-user nonroot \
  "system:serviceaccount:${NAMESPACE_EXPORTER}:${SA_EXPORTER}"

# ------------------------------------------------------------
# 5. Verificar ServiceMonitor y targets
# ------------------------------------------------------------
echo "==> [5/7] Verificando ServiceMonitor..."
oc get servicemonitor -n "$NAMESPACE_EXPORTER"

echo ""
echo "    Para verificar targets en Prometheus ejecuta en otra terminal:"
echo "    oc port-forward svc/prometheus-user-workload 9090:9090 -n openshift-user-workload-monitoring"
echo "    Luego abre: http://localhost:9090/targets"
echo ""

# ------------------------------------------------------------
# 6. Instalar Grafana
# ------------------------------------------------------------
echo "==> [6/7] Instalando Grafana..."
oc new-project "$NAMESPACE_GRAFANA" 2>/dev/null || \
  echo "    Proyecto ya existe, continuando..."

helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install my-grafana grafana/grafana \
  -n "$NAMESPACE_GRAFANA" \
  -f grafana-values-v2.yaml \

echo "==> [6b/7] Eliminando runAsUser y runAsGroup del deployment de Grafana..."
oc patch deployment my-grafana \
  -n "$NAMESPACE_GRAFANA" \
  --type='json' \
  -p='[
    {"op":"remove","path":"/spec/template/spec/securityContext/runAsUser"},
    {"op":"remove","path":"/spec/template/spec/securityContext/runAsGroup"},
    {"op":"remove","path":"/spec/template/spec/securityContext/fsGroup"}
  ]'

# ------------------------------------------------------------
# 7. Exponer Grafana via Route
# ------------------------------------------------------------
echo "==> [7/7] Exponiendo Grafana..."
oc create route edge grafana-route \
  --service=my-grafana \
  -n "$NAMESPACE_GRAFANA" \
  --insecure-policy=Allow 2>/dev/null || true

GRAFANA_URL=$(oc get route grafana-route -n "$NAMESPACE_GRAFANA" -o jsonpath='{.spec.host}')

# ------------------------------------------------------------
# 8. Crear SA para datasource y configurar via API de Grafana
# ------------------------------------------------------------
echo "==> [8/7] Configurando datasource Thanos en Grafana via API..."

oc create serviceaccount "$SA_GRAFANA_DS" -n "$NAMESPACE_GRAFANA" 2>/dev/null || true
oc adm policy add-cluster-role-to-user cluster-monitoring-view \
  "system:serviceaccount:${NAMESPACE_GRAFANA}:${SA_GRAFANA_DS}"

TOKEN=$(oc create token "$SA_GRAFANA_DS" -n "$NAMESPACE_GRAFANA" --duration=8760h)
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')

echo "    Thanos Querier host: $THANOS_HOST"
echo "    Esperando que Grafana este disponible..."
sleep 10

curl -sk -X POST "https://${GRAFANA_URL}/api/datasources" \
  -H "Content-Type: application/json" \
  -u admin:admin123 \
  -d "{
    \"name\": \"Thanos\",
    \"type\": \"prometheus\",
    \"url\": \"https://${THANOS_HOST}\",
    \"access\": \"proxy\",
    \"isDefault\": true,
    \"jsonData\": {
      \"tlsSkipVerify\": true,
      \"httpHeaderName1\": \"Authorization\"
    },
    \"secureJsonData\": {
      \"httpHeaderValue1\": \"Bearer ${TOKEN}\"
    }
  }"

echo ""
echo "============================================================"
echo "Instalacion completada."
echo "Grafana: https://${GRAFANA_URL}"
echo "Usuario: admin / Password: admin123"
echo "Dashboard 'x509 Certificates' disponible en la carpeta Default"
echo "============================================================"
