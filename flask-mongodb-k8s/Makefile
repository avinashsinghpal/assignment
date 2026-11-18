IMAGE ?= avinashsingh231/flask-mongodb-app:v1.0.0
NAMESPACE ?= flask-app

.PHONY: all build load deploy test clean

all: build load deploy test

build:
	docker build -t $(IMAGE) ./app

load:
	minikube image load $(IMAGE)

deploy:
	kubectl apply -f k8s/00-namespace.yaml
	kubectl apply -f k8s/01-secret.yaml
	kubectl apply -f k8s/02-mongo-pv-pvc.yaml
	kubectl apply -f k8s/04-mongo-service.yaml
	kubectl apply -f k8s/03-mongo-statefulset.yaml
	kubectl wait --for=condition=ready pod/mongodb-0 -n $(NAMESPACE) --timeout=120s
	kubectl apply -f k8s/05-flask-deployment.yaml
	kubectl apply -f k8s/06-flask-service.yaml
	kubectl rollout status deployment/flask-deployment -n $(NAMESPACE) --timeout=120s
	kubectl apply -f k8s/07-hpa.yaml
	kubectl apply -f k8s/08-networkpolicy.yaml
	kubectl apply -f k8s/09-pdb.yaml

test:
	./deploy.sh test

clean:
	kubectl delete namespace $(NAMESPACE) --ignore-not-found
	kubectl delete pv mongo-pv --ignore-not-found
