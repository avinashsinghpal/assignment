#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="flask-app"
IMAGE="avinashsingh231/flask-mongodb-app:v1.0.0"

case "${1:-deploy}" in
  build)
    echo "=== Building Docker image ${IMAGE} ==="
    docker build -t "${IMAGE}" ./app
    ;;

  load)
    echo "=== Loading image into Minikube ==="
    minikube image load "${IMAGE}"
    ;;

  deploy)
    echo "=== Creating Namespace & Secrets ==="
    kubectl apply -f k8s/00-namespace.yaml
    kubectl apply -f k8s/01-secret.yaml

    echo "=== Applying PV and PVC ==="
    minikube ssh "sudo rm -rf /data/mongo/* /data/mongo/.[!.]* 2>/dev/null; sudo mkdir -p /data/mongo; sudo chmod 777 /data/mongo"
    kubectl apply -f k8s/02-mongo-pv-pvc.yaml

    echo "=== Deploying MongoDB StatefulSet and Service ==="
    kubectl apply -f k8s/04-mongo-service.yaml
    kubectl apply -f k8s/03-mongo-statefulset.yaml

    echo "Waiting for MongoDB pod to be ready..."
    kubectl wait --for=condition=ready pod/mongodb-0 -n "${NAMESPACE}" --timeout=120s

    echo "=== Deploying Flask Deployment and NodePort Service ==="
    kubectl apply -f k8s/05-flask-deployment.yaml
    kubectl apply -f k8s/06-flask-service.yaml

    echo "Waiting for Flask deployment roll out..."
    kubectl rollout status deployment/flask-deployment -n "${NAMESPACE}" --timeout=120s

    echo "=== Applying HPA and Resilience Resources ==="
    kubectl apply -f k8s/07-hpa.yaml
    if [ -f k8s/08-networkpolicy.yaml ]; then
      kubectl apply -f k8s/08-networkpolicy.yaml
    fi
    if [ -f k8s/09-pdb.yaml ]; then
      kubectl apply -f k8s/09-pdb.yaml
    fi

    echo "=== Deployment Completed Successfully ==="
    kubectl get all,pv,pvc,hpa -n "${NAMESPACE}"
    ;;

  test)
    echo "=== Testing Deployment via Service URL ==="
    URL=$(minikube service flask-service -n "${NAMESPACE}" --url | head -n 1)
    echo "Endpoint URL: ${URL}"
    echo "--- GET /health ---"
    curl -s "${URL}/health" && echo ""
    echo "--- GET / ---"
    curl -s "${URL}/" && echo ""
    echo "--- POST /data ---"
    curl -s -X POST -H "Content-Type: application/json" -d '{"assignment":"kubernetes-intern","verified":true}' "${URL}/data" && echo ""
    echo "--- GET /data ---"
    curl -s "${URL}/data" && echo ""
    ;;

  clean)
    echo "=== Cleaning up Kubernetes Resources ==="
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found
    kubectl delete pv mongo-pv --ignore-not-found
    echo "=== Cleanup completed ==="
    ;;

  *)
    echo "Usage: $0 {build|load|deploy|test|clean}"
    exit 1
    ;;
esac
