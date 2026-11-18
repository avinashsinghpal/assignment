[CmdletBinding()]
param (
    [ValidateSet("build", "load", "deploy", "test", "clean")]
    [string]$Action = "deploy"
)

$Namespace = "flask-app"
$Image = "avinashsingh231/flask-mongodb-app:v1.0.0"

switch ($Action) {
    "build" {
        Write-Host "=== Building Docker image $Image ===" -ForegroundColor Cyan
        docker build -t $Image .\app
    }

    "load" {
        Write-Host "=== Loading image into Minikube ===" -ForegroundColor Cyan
        minikube image load $Image
    }

    "deploy" {
        Write-Host "=== Applying Namespace and Secrets ===" -ForegroundColor Cyan
        kubectl apply -f k8s/00-namespace.yaml
        kubectl apply -f k8s/01-secret.yaml

        Write-Host "=== Applying PV and PVC ===" -ForegroundColor Cyan
        minikube ssh "sudo rm -rf /data/mongo/* /data/mongo/.[!.]* 2>/dev/null; sudo mkdir -p /data/mongo; sudo chmod 777 /data/mongo"
        kubectl apply -f k8s/02-mongo-pv-pvc.yaml

        Write-Host "=== Deploying MongoDB StatefulSet and Service ===" -ForegroundColor Cyan
        kubectl apply -f k8s/04-mongo-service.yaml
        kubectl apply -f k8s/03-mongo-statefulset.yaml

        Write-Host "Waiting for MongoDB pod to be ready..." -ForegroundColor Yellow
        kubectl wait --for=condition=ready pod/mongodb-0 -n $Namespace --timeout=120s

        Write-Host "=== Deploying Flask Deployment and Service ===" -ForegroundColor Cyan
        kubectl apply -f k8s/05-flask-deployment.yaml
        kubectl apply -f k8s/06-flask-service.yaml

        Write-Host "Waiting for Flask deployment rollout..." -ForegroundColor Yellow
        kubectl rollout status deployment/flask-deployment -n $Namespace --timeout=120s

        Write-Host "=== Applying HPA, NetworkPolicy, PDB ===" -ForegroundColor Cyan
        kubectl apply -f k8s/07-hpa.yaml
        if (Test-Path "k8s/08-networkpolicy.yaml") {
            kubectl apply -f k8s/08-networkpolicy.yaml
        }
        if (Test-Path "k8s/09-pdb.yaml") {
            kubectl apply -f k8s/09-pdb.yaml
        }

        Write-Host "=== Deployment Status ===" -ForegroundColor Green
        kubectl get all,pv,pvc,hpa -n $Namespace
    }

    "test" {
        Write-Host "=== Testing Flask Service ===" -ForegroundColor Cyan
        $url = "http://localhost:5000"
        try {
            $null = Invoke-RestMethod -Uri "$url/health" -TimeoutSec 2 -ErrorAction Stop
        }
        catch {
            Write-Host "Establishing port-forward connection on port 5000..." -ForegroundColor Yellow
            $null = Start-Process kubectl -ArgumentList "port-forward svc/flask-service -n $Namespace 5000:5000" -PassThru -NoNewWindow
            Start-Sleep -Seconds 2
        }
        Write-Host "Endpoint: $url" -ForegroundColor Green

        Write-Host "--- GET /health ---"
        curl.exe -s "$url/health"; Write-Output ""

        Write-Host "--- GET / ---"
        curl.exe -s "$url/"; Write-Output ""

        Write-Host "--- POST /data ---"
        curl.exe -s -X POST -H "Content-Type: application/json" -d "{\`"assignment\`":\`"kubernetes-intern\`",\`"verified\`":true}" "$url/data"; Write-Output ""

        Write-Host "--- GET /data ---"
        curl.exe -s "$url/data"; Write-Output ""
    }

    "clean" {
        Write-Host "=== Cleaning up Kubernetes Resources ===" -ForegroundColor Yellow
        kubectl delete namespace $Namespace --ignore-not-found
        kubectl delete pv mongo-pv --ignore-not-found
        Write-Host "=== Cleanup Complete ===" -ForegroundColor Green
    }
}
