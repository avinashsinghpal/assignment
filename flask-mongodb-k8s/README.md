# Production Flask + MongoDB on Kubernetes (Minikube)

A production-grade, highly available deployment of a Python Flask application connected to an authenticated MongoDB database running on a local Minikube Kubernetes cluster.

---

## 1. Overview & Architecture

The architecture consists of a 2-tier microservice model deployed in a dedicated `flask-app` namespace:
- **Frontend / API Tier**: Horizontally scalable Flask application served via Gunicorn WSGI workers, exposed externally via a `NodePort` Service, and managed by a Horizontal Pod Autoscaler (HPA v2) and a PodDisruptionBudget (PDB).
- **Database Tier**: Persistent MongoDB stateful instance managed by a `StatefulSet`, paired with a headless `ClusterIP` Service for deterministic DNS resolution, backed by a persistent `hostPath` Volume Claim.
- **Security & Networking**: Credentials stored in Kubernetes Secrets and injected safely as environment variables, with strict resource requests/limits and NetworkPolicy ingress isolation.

> [!NOTE]
> **NetworkPolicy CNI Enforcement**: Kubernetes NetworkPolicies require a CNI network plugin that supports enforcement (such as Calico via `minikube start --cni=calico`). On a default Minikube cluster using the standard driver and CNI, the NetworkPolicy manifest is accepted and stored by the API server, but network rules are **not actively enforced**. For full ingress isolation in production, start Minikube with `--cni=calico`.

### Architecture Diagram

```mermaid
flowchart TD
    subgraph External ["External Access (Host Machine)"]
        User["Client / Browser / curl"]
    end

    subgraph Cluster ["Minikube Kubernetes Cluster (Namespace: flask-app)"]
        subgraph IngressRouting ["Service Layer"]
            FlaskSvc["Flask Service<br/>(NodePort: 30005 / Port: 5000)"]
            MongoSvc["Headless MongoDB Service<br/>(ClusterIP: None / Port: 27017)<br/>DNS: mongodb-service.flask-app.svc.cluster.local"]
        end

        subgraph ComputeWorkloads ["Workload Layer"]
            subgraph FlaskDeploy ["Flask Deployment (Replicas: 2 - 5)"]
                FlaskPod1["Flask Pod 1<br/>Gunicorn + Python 3.11<br/>(non-root appuser:10001)"]
                FlaskPod2["Flask Pod 2<br/>Gunicorn + Python 3.11<br/>(non-root appuser:10001)"]
            end

            subgraph MongoSts ["Stateful Workload"]
                MongoPod["MongoDB Pod (mongodb-0)<br/>mongo:latest<br/>--wiredTigerCacheSizeGB 0.25"]
            end
        end

        subgraph StorageLayer ["Persistence Layer"]
            PVC["PersistentVolumeClaim<br/>(mongo-pvc: 1Gi)"]
            PV["PersistentVolume<br/>(mongo-pv: hostPath /data/mongo)"]
        end

        subgraph Management ["Autoscaling & Configuration"]
            HPA["Horizontal Pod Autoscaler<br/>(Target: 70% CPU, Min: 2, Max: 5)"]
            MetricsSvc["metrics-server Addon"]
            PDB["PodDisruptionBudget<br/>(minAvailable: 1)"]
            Secret["Kubernetes Secret<br/>(mongodb-secret)"]
            NetPol["NetworkPolicy<br/>(Allow Ingress only from Flask)"]
        end
    end

    User -->|"HTTP Requests"| FlaskSvc
    FlaskSvc -->|"Round Robin Load Balancing"| FlaskPod1
    FlaskSvc -->|"Round Robin Load Balancing"| FlaskPod2

    FlaskPod1 -->|"TCP :27017 (Auth)"| MongoSvc
    FlaskPod2 -->|"TCP :27017 (Auth)"| MongoSvc
    MongoSvc -->|"Direct Pod DNS Routing"| MongoPod

    MongoPod --- PVC
    PVC --- PV

    HPA -.->|"Scrapes CPU"| MetricsSvc
    MetricsSvc -.->|"Monitors Pods"| FlaskDeploy
    HPA -.->|"Scales Replicas (2-5)"| FlaskDeploy
    PDB -.->|"Guarantees HA"| FlaskDeploy
    Secret -.->|"Injects Credentials"| FlaskPod1
    Secret -.->|"Injects Credentials"| FlaskPod2
    Secret -.->|"Injects Root Auth"| MongoPod
    NetPol -.->|"Restricts Ingress"| MongoPod
```

---

## 2. Prerequisites & Verified Tooling

The environment was validated and verified on the local host before execution:

| Tool | Verified Version | Purpose |
| :--- | :--- | :--- |
| **Python** | `Python 3.15.2` (Host) / `Python 3.9.13` (venv) | Application development & virtual environment |
| **pip** | `pip 26.2.2` | Dependency management |
| **Docker** | `29.9.3` (build 5457199) | Container engine & Minikube VM driver |
| **Minikube** | `v1.39.0` (commit 7a9f6a8) | Local single-node Kubernetes cluster |
| **kubectl** | Client `v1.36.1` (Server `v1.37.0`) | Cluster CLI management |
| **Git** | `2.56.0.windows.4` | Version control |
| **curl** | `curl 8.21.0` | HTTP client for verification |
| **Docker Hub** | Account: `avinashsingh231` | Image repository namespace |

---

## 3. Quick Start

Deploy the entire infrastructure with a single script:

### Linux / macOS / WSL2
```bash
cd flask-mongodb-k8s

# 1. Build and load the Docker image into Minikube
./deploy.sh build
./deploy.sh load

# 2. Deploy all manifests and wait for readiness
./deploy.sh deploy

# 3. Test all endpoints
./deploy.sh test
```

### Windows (PowerShell)
```powershell
cd flask-mongodb-k8s

# 1. Build and load the Docker image into Minikube
.\deploy.ps1 -Action build
.\deploy.ps1 -Action load

# 2. Deploy all manifests and wait for readiness
.\deploy.ps1 -Action deploy

# 3. Test all endpoints
.\deploy.ps1 -Action test
```

---

## 4. Detailed Step-by-Step Deployment on Minikube

### Step 1: Start Minikube Cluster
Start Minikube with the Docker driver allocating at least 2 CPUs and 4096MB memory:
```bash
minikube start --driver=docker --cpus=2 --memory=4096
```

### Step 2: Enable the Metrics Server Addon
The Horizontal Pod Autoscaler requires `metrics-server` to collect pod CPU metrics:
```bash
minikube addons enable metrics-server
```

### Step 3: Build & Load the Docker Image
```bash
# Build locally
docker build -t avinashsingh231/flask-mongodb-app:v1.0.0 ./app

# Load directly into Minikube's container runtime
minikube image load avinashsingh231/flask-mongodb-app:v1.0.0
minikube image load mongo:latest
```

### Step 4: Apply Kubernetes Manifests in Numeric Order
Manifests are structured cleanly in `k8s/` and must be applied sequentially:

```bash
# 00. Create dedicated namespace
kubectl apply -f k8s/00-namespace.yaml

# 01. Create Secret with credentials
kubectl apply -f k8s/01-secret.yaml

# Pre-create hostPath directory (root-owned by default; mongod runs as non-root UID 999)
minikube ssh "sudo mkdir -p /data/mongo && sudo chmod 777 /data/mongo"

# 02. Create PersistentVolume and PersistentVolumeClaim
kubectl apply -f k8s/02-mongo-pv-pvc.yaml

# 03 & 04. Deploy MongoDB Headless Service and StatefulSet
kubectl apply -f k8s/04-mongo-service.yaml
kubectl apply -f k8s/03-mongo-statefulset.yaml

# Wait for MongoDB initialization and readiness
kubectl wait --for=condition=ready pod/mongodb-0 -n flask-app --timeout=120s

# 05 & 06. Deploy Flask Deployment and NodePort Service
kubectl apply -f k8s/05-flask-deployment.yaml
kubectl apply -f k8s/06-flask-service.yaml

# Wait for Flask deployment rollout
kubectl rollout status deployment/flask-deployment -n flask-app --timeout=120s

# 07. Deploy HorizontalPodAutoscaler
kubectl apply -f k8s/07-hpa.yaml

# 08 & 09 (Bonuses). Deploy NetworkPolicy and PodDisruptionBudget
kubectl apply -f k8s/08-networkpolicy.yaml
kubectl apply -f k8s/09-pdb.yaml
```

> **Note on Storage**: `deploy.sh` and `deploy.ps1` automatically wipe and recreate `/data/mongo` inside Minikube on each deploy run to guarantee a clean, uncorrupted database state for authentication bootstrapping.

### Step 5: Verify Deployment Status
```bash
kubectl get all,pv,pvc,hpa,pdb,netpol -n flask-app
```

### Step 6: Access the Application
Get the URL exposed by the NodePort service:
```bash
minikube service flask-service -n flask-app --url
# Alternatively, establish a direct port-forward:
kubectl port-forward svc/flask-service -n flask-app 5000:5000
```

---

## 5. Docker Build and Push Instructions

### Local Build
```bash
docker build -t avinashsingh231/flask-mongodb-app:v1.0.0 ./app
```

### Push to Docker Hub
To push the image to Docker Hub under your username:
```bash
# 1. Login to Docker Hub (prompts for your password / Personal Access Token)
docker login -u avinashsingh231

# 2. Tag explicitly (already tagged during build, but shown for completeness)
docker tag avinashsingh231/flask-mongodb-app:v1.0.0 avinashsingh231/flask-mongodb-app:v1.0.0

# 3. Push to registry
docker push avinashsingh231/flask-mongodb-app:v1.0.0
```

### Minikube Alternative (`minikube image load`)
To deploy locally without pushing to Docker Hub or needing credentials:
```bash
minikube image load avinashsingh231/flask-mongodb-app:v1.0.0
```
*Note on `eval $(minikube docker-env)`*: On Linux/macOS or bash shells, executing `eval $(minikube docker-env)` points your host `docker` CLI directly to Minikube's internal Docker daemon, allowing you to build directly inside Minikube (`docker build -t avinashsingh231/flask-mongodb-app:v1.0.0 ./app`) without copying layers.

---

## 6. Virtual Environment Benefits

Using Python virtual environments (`venv`) provides critical engineering advantages:
1. **Dependency Isolation**: Prevents dependency version conflicts between different projects on the same machine.
2. **Version Pinning & Reproducibility**: Guarantees that exact specified versions (`Flask==2.0.2`, `Werkzeug==2.0.3`, `pymongo==3.12.0`) are installed without unexpected updates or breaking changes from newer upstream packages.
3. **Host System Protection**: Leaves the global operating system Python environment clean and unpolluted, eliminating the risk of breaking system packages or OS tools that depend on system Python.
4. **Environment Determinism**: Mirroring production dependencies in a local virtual environment eliminates "works on my machine" bugs prior to containerization.

---

## 7. DNS Resolution Deep Dive

Kubernetes provides built-in DNS management via **CoreDNS**.

### Standard Services vs. Headless Services
- **Standard Service (`flask-service`)**:
  - Kubernetes assigns a virtual IP (`ClusterIP: 10.97.150.249`).
  - CoreDNS resolves `flask-service.flask-app.svc.cluster.local` to this single ClusterIP.
  - `kube-proxy` (via iptables or IPVS) load-balances traffic arriving at the ClusterIP across the ready backend pods.

- **Headless Service (`mongodb-service` with `clusterIP: None`)**:
  - CoreDNS does **not** assign a virtual cluster IP.
  - Instead, DNS queries for `mongodb-service.flask-app.svc.cluster.local` return direct `A` records containing the IP addresses of all backing pods (`10.244.0.9`).
  - Furthermore, pairing with a `StatefulSet` enables **predictable, per-pod DNS records**:
    $$\text{pod-name}.\text{service-name}.\text{namespace}.\text{svc}.\text{cluster}.\text{local}$$
    For pod index 0:
    ```
    mongodb-0.mongodb-service.flask-app.svc.cluster.local
    ```
  - This guarantees the Flask application connects directly to the dedicated MongoDB instance without intermediary proxy layers.

### Configuration in Flask
The Flask application reads `MONGO_HOST` from the environment:
```yaml
env:
  - name: MONGO_HOST
    value: "mongodb-service.flask-app.svc.cluster.local"
```
No hardcoded IP addresses are used. If Flask and MongoDB reside in the same namespace, the short name `mongodb-service` also resolves correctly via the search domain configuration in `/etc/resolv.conf`.

---

## 8. Resource Requests and Limits Deep Dive

Kubernetes container resource management separates **Scheduling** from **Enforcement**:

| Metric | Requests | Limits |
| :--- | :--- | :--- |
| **CPU** | `200m` (0.2 cores) | `500m` (0.5 cores) |
| **Memory** | `250M` (250 Megabytes) | `500M` (500 Megabytes) |

### Requests (Scheduling)
- **What it is**: The guaranteed baseline resources reserved for the container.
- **How it works**: The Kubernetes `kube-scheduler` calculates node capacity based on the sum of container *requests*. A node with 2 CPUs will only accept pods whose combined CPU requests are $\le$ 2 CPUs.
- **HPA Relationship**: The Horizontal Pod Autoscaler calculates target CPU utilization as a percentage of **requests**, NOT limits:
  $$\text{Utilization \%} = \frac{\text{Current CPU Usage}}{\text{CPU Request (200m)}} \times 100$$
  Therefore, an HPA target of 70% triggers scaling when pod CPU consumption exceeds:
  $$200\text{m} \times 0.70 = 140\text{m}$$

### Limits (Enforcement & Throttling vs OOMKill)
- **CPU Limits (Throttling)**: CPU is a compressible resource. When a container attempts to consume more CPU than its limit (`500m`), the Linux kernel CFS (Completely Fair Scheduler) **throttles** execution cycles. The process is never killed; it simply runs slower.
- **Memory Limits (OOMKill)**: Memory is an incompressible resource. When a container exceeds its memory limit (`500M`), the Linux kernel cgroup memory controller terminates the process immediately with a **SIGKILL (Exit Code 137)** (`OOMKilled`).
- **Mitigation for MongoDB**: Because MongoDB's default WiredTiger storage cache attempts to use 50% of total host RAM (which in our 16GB system would consume 8GB), running without tuning inside a 500M limit would trigger an immediate OOMKill. We explicitly configure `--wiredTigerCacheSizeGB 0.25` (256MB) in the StatefulSet container `args`, ensuring the WiredTiger storage engine cache remains safely within the 500M container threshold.

---

## 9. Design Choices & Trade-off Analysis

| Decision | Selected Choice | Alternative Considered | Why the Selected Choice Won & Why Alternative Was Rejected |
| :--- | :--- | :--- | :--- |
| **MongoDB Workload** | **StatefulSet** | Deployment | **StatefulSet** provides stable persistent network IDs (`mongodb-0`), ordered startup/shutdown, and dedicated persistent storage binding. **Deployment** was rejected because pods are ephemeral and fungible; restarting a deployment can attach volumes to new random pod names and break stateful data persistence. |
| **MongoDB Service** | **Headless ClusterIP (`None`)** | ClusterIP / NodePort | **Headless Service** allows direct DNS addressing to the individual pod (`mongodb-0.mongodb-service`) and avoids unnecessary NAT/proxy overhead. Exposing via **NodePort** was rejected as a severe security vulnerability (database should never be directly accessible from the public network). |
| **Credentials** | **Kubernetes Secret** | ConfigMap / Plaintext | **Secret** (`type: Opaque`) encrypts/obfuscates credentials and integrates with Kubernetes RBAC and audit logging. **ConfigMap** was rejected because it is intended strictly for non-sensitive configuration; storing passwords in ConfigMaps exposes plaintext credentials in cluster logs and git repositories. |
| **Storage Class** | **hostPath PV + PVC** | Dynamic Provisioning (`hostpath-storage`) | **Static hostPath PV (`02-mongo-pv-pvc.yaml`)** satisfies the strict assignment contract requiring a dedicated `PersistentVolume` bound to a `PersistentVolumeClaim` with `storageClassName: manual`. While Minikube supports dynamic storage provisioners, static binding gives deterministic control over the exact host mount path (`/data/mongo`). |
| **Flask Expose** | **NodePort** | LoadBalancer / Ingress | **NodePort** natively works out-of-the-box on local Minikube without external cloud infrastructure or configuring ingress controllers. **LoadBalancer** requires `minikube tunnel` running in privileged mode, and **Ingress** requires additional ingress-nginx addons. |
| **MongoDB Topology** | **Standalone Instance** | Multi-node Replica Set | **Standalone** satisfies all assignment requirements while staying strictly within the 2 CPU / 4GB Minikube intern resource constraints. A 3-node **Replica Set** was rejected because it triples resource consumption (1.5GB RAM minimum) and requires complex election orchestration not required for this tier. |
| **WSGI Server** | **Gunicorn** | Flask Built-in Dev Server | **Gunicorn** is a battle-tested, pre-fork worker WSGI server that handles concurrent connections, request timeouts, and worker worker-recycling. Flask's built-in `werkzeug` server is single-threaded, explicitly unsuited for production, and lacks proper concurrency. |
| **NetworkPolicy Ingress** | **Declared (Targeted Ingress)** | Open Namespace Networking | **NetworkPolicy** enforces the principle of least privilege by restricting MongoDB ingress to pods matching label `app: flask-app`. **CNI note**: NetworkPolicy enforcement requires a compatible CNI plugin (e.g. `minikube start --cni=calico`); on default Minikube the manifest is accepted by the API server but not actively enforced. |

---

## 10. Testing Scenarios & Verification Results

All tests were executed against the live cluster. Raw execution logs are saved in `tests/`:

![Cluster Ready](docs/screenshots/01-cluster-ready.png)
*All cluster workloads in the `flask-app` namespace running and ready.*

### 1. Database CRUD Verification (`tests/01_database_crud.log`)
- `GET /health` -> `HTTP 200 OK` (`{"database":"connected","status":"healthy"}`)
- `GET /` -> `HTTP 200 OK` (`Welcome to the Flask app! The current time is: ...`)
- `POST /data` with valid JSON -> `HTTP 201 CREATED` (`{"status":"Data inserted"}`)
- `GET /data` -> `HTTP 200 OK` (`[{"source":"minikube-k8s","status":"success"}, ...]`)
- `POST /data` with invalid non-JSON -> `HTTP 400 BAD REQUEST` (`{"error":"Invalid or missing JSON payload"}`)

![Endpoints Working](docs/screenshots/06-endpoints-working.png)
*All application endpoints verified working with correct HTTP status codes and responses.*

### 2. MongoDB Authentication Verification (`tests/02_auth_verification.log`)
Demonstrated inside the cluster via in-cluster client:
- **No Credentials**: Access refused by MongoDB engine:
  `OperationFailure: Command find requires authentication (code: 13, Unauthorized)`
- **Incorrect Credentials**: Authentication rejected:
  `OperationFailure: Authentication failed (code: 18, AuthenticationFailed)`
- **Correct Credentials from Secret**: Authenticated and document retrieved:
  `AUTHENTICATED SUCCESSFULLY -> Document: {'source': 'minikube-k8s', 'status': 'success'}`

![MongoDB Authentication Test](docs/screenshots/07-auth-test.png)
*Authentication verification proving unauthorized access is blocked while valid secret credentials succeed.*

### 3. Data Persistence Verification (`tests/03_data_persistence.log`)
- Inserted unique test record: `{"test_id":"persistence-712421697"}` via `POST /data`.
- Forcibly deleted the `mongodb-0` pod: `kubectl delete pod mongodb-0 -n flask-app`.
- Waited for StatefulSet to spin up a new replacement pod and pass readiness checks.
- Queried `GET /data`: Document `persistence-712421697` was intact and returned immediately from the mounted `hostPath` volume.

![Data Persistence Test](docs/screenshots/08-persistence-test.png)
*Persistent storage validation: MongoDB data persists across pod recreation via hostPath PV.*

### 4. Zero-Downtime Resilience Test (`tests/04_resilience_pod_failure.log`)
- Sent 15 continuous HTTP requests while simultaneously executing `kubectl delete pod` on one of the active Flask pods.
- Result: **15 / 15 requests succeeded with HTTP 200 (100% availability)**.
- `flask-service` seamlessly routed traffic to the healthy replica, while the Deployment and PDB spawned a replacement pod.

![Resource Limits and Resilience](docs/screenshots/09-resource-limits.png)
*Zero downtime and resource enforcement during pod termination and rescheduling.*

### 5. Horizontal Pod Autoscaler (HPA) Load Test (`tests/05_hpa_autoscaling.log`)

The autoscaling behavior was rigorously verified by deploying an in-cluster load generator (`kubectl create deployment load-gen --image=busybox`) generating high-frequency parallel `wget` HTTP traffic against `http://flask-service:5000/data`.

#### Test Execution Timeline

| Timestamp | Phase | Pod CPU (avg / pod) | HPA Metric (% of 200m request) | Flask Replicas | Observations |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **01:49:39** | Baseline (Idle) | ~4m / pod | 2% / 70% | 2 (Min) | Baseline idle state prior to load injection |
| **01:50:20** | Traffic Start (8 busybox pods) | 65m / pod | 30% / 70% | 2 | CPU begins rising; load distributed across 2 pods |
| **01:51:50** | Scaled Load (16 busybox pods) | 235m / pod | **117% / 70%** | 2 -> 4 | CPU exceeds 70% (140m) threshold; HPA rescales |
| **01:53:14** | Scale-Up Event | 110m / pod | **57% / 70%** | **4 (Scaled)** | HPA events show `New size: 4; reason: cpu utilization above target` |
| **01:53:28** | Peak Load (24 busybox pods) | 105m / pod | 52% / 70% | 4 | Load successfully distributed across 4 healthy replicas |
| **01:55:12** | Load Stopped | <20m / pod | 10% / 70% | 4 | `load-gen` deployment deleted; traffic halts |
| **01:55:23** | Cool-down Window | ~4m / pod | 2% / 70% | 4 -> 2 | HPA 60s stabilization window evaluates scale-down |
| **01:55:35** | Scale-Down Event | ~4m / pod | 2% / 70% | **2 (Baseline)** | HPA rescales: `New size: 2; reason: All metrics below target` |

> **Note on Maximum Replicas (4 vs 5)**: The HPA reached a peak of **4 replicas**. It did not scale to the maximum limit of 5 because adding 2 new pods expanded the total CPU request capacity to 800m ($4 \times 200\text{m}$). The aggregate load of 24 concurrent busybox loops was absorbed at ~105m per pod (52% utilization), which fell below the 70% scaling threshold before a 5th replica was required.

#### Screenshots

![HPA Baseline](docs/screenshots/02-hpa-baseline.png)
*HPA baseline: 2 replicas operating at idle CPU (~2%).*

![HPA Scaling Up](docs/screenshots/03-hpa-scaling-up.png)
*HPA scaling up: CPU utilization surges past the 70% threshold under 16 load-gen clients.*

![HPA Peak Utilization](docs/screenshots/04-hpa-peak.png)
*HPA peak load: 4 replicas running concurrently with load evenly balanced.*

![HPA Scale Down](docs/screenshots/05-hpa-scale-down.png)
*HPA cool-down: traffic terminates, stabilization window elapses, and deployment returns to 2 replicas.*

#### Issues Encountered & Engineering Mitigations

1. **Flask Liveness Probe Timeouts Under Heavy Traffic**:
   - *Observation*: During initial stress testing with 25 concurrent connections, gunicorn workers were fully saturated serving database queries, causing `/health` endpoint responses to momentarily exceed the original `timeoutSeconds: 3` threshold. Kubelet failed the probe 3 consecutive times, restarting a Flask pod (`context deadline exceeded`).
   - *Mitigation*: Updated `k8s/05-flask-deployment.yaml` to raise `livenessProbe.timeoutSeconds: 5` and `livenessProbe.failureThreshold: 5`. After re-applying and repeating the test, all 4 replicas served sustained concurrency with **0 restarts** throughout the entire test.

2. **Metrics-Server Initial Polling Lag (`<unknown>`)**:
   - *Observation*: Immediately following a deployment rollout, `kubectl get hpa` reports `cpu: <unknown>/70%` for roughly 30 to 45 seconds.
   - *Mitigation*: Documented as expected Kubernetes metrics-server behavior; the metrics scraper queries the kubelet summary API on a 30-second cadence.

---

### 6. Container Image & Registry Verification

![Docker Hub Repository Image](docs/screenshots/10-dockerhub-image.png)
*Docker Hub container registry showing `avinashsingh231/flask-mongodb-app:v1.0.0` repository and tag.*

---

## 11. Known Gotchas & SRE Observations

1. **`MONGO_INITDB_*` Requires an Empty Directory**:
   MongoDB's entrypoint script (`docker-entrypoint.sh`) only evaluates root credentials and creates the admin user if `/data/db` is completely empty. If the container is restarted with pre-existing data files from an unauthenticated session, initialization is skipped.
2. **`command` vs `args` in Docker Containers**:
   Specifying `command: ["mongod"]` in Kubernetes overrides the container's `ENTRYPOINT`, which completely bypasses `docker-entrypoint.sh` and skips user creation. The correct approach is omitting `command` and passing arguments via `args: ["mongod", ...]`.
3. **Node.js `mongosh` Probe Memory Footprint & Timeouts**:
   `mongosh` (the default interactive shell in modern MongoDB images) is a Node.js V8 application. Because Node.js initialization can take several seconds under constrained CPU limits, setting a 10s `timeoutSeconds` across all probes and a dedicated `startupProbe` with `failureThreshold: 25` (allowing up to 140s for initial database bootstrapping) prevents the kubelet from prematurely terminating the container before MongoDB is fully operational.
4. **HPA `<unknown>` Status**:
   Immediately after deploying an HPA, `kubectl get hpa` displays `cpu: <unknown>/70%`. This is expected behavior while `metrics-server` completes its first 30-60 second polling cycle.
5. **Minikube Docker Driver Networking on Windows**:
   Because Docker Desktop runs within a WSL2 / Hyper-V VM, NodePorts on the Minikube node IP are not directly routable from the Windows host network. Running `minikube service flask-service -n flask-app --url` or `kubectl port-forward` bridges host traffic into the cluster.

---

## 12. Troubleshooting & Cleanup

### Troubleshooting Commands
```bash
# Check pod events and termination reasons
kubectl describe pod <pod-name> -n flask-app

# Inspect live application logs
kubectl logs -n flask-app deployment/flask-deployment -c flask-app --tail=50 -f
kubectl logs -n flask-app mongodb-0 --tail=50 -f

# Check real-time resource utilization
kubectl top nodes
kubectl top pods -n flask-app

# Inspect HPA events
kubectl describe hpa flask-hpa -n flask-app
```

### Complete Cleanup
```bash
# Delete all resources in the flask-app namespace and the PV
kubectl delete namespace flask-app
kubectl delete pv mongo-pv

# Stop Minikube cluster
minikube stop
```

---

## 13. Future Production Improvements

1. **MongoDB Replica Set with Operator**: Migrate standalone MongoDB to a 3-node replica set using the MongoDB Community Kubernetes Operator for automated backups, rolling updates, and automatic primary failover.
2. **Ingress with TLS Termination**: Deploy an Ingress Controller (`ingress-nginx`) with `cert-manager` for automated Let's Encrypt SSL/TLS certificates and path-based routing.
3. **Secrets Management**: Replace base64/stringData Kubernetes secrets with HashiCorp Vault or AWS Secrets Manager via the External Secrets Operator (ESO).
4. **CI/CD Pipeline**: Implement GitHub Actions workflows to run unit tests, trigger security scanning (Trivy), build signed multi-arch container images, and deploy via Helm or ArgoCD (GitOps).
