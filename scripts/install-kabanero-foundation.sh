#!/bin/bash

set -Eeox pipefail

### Configuration ###



# Branch/Release of Kabanero #
KABANERO_BRANCH="${KABANERO_BRANCH:-0.1.0}"

# Kserving domain matches openshift_master_default_subdomain #
# openshift_master_default_subdomain="${openshift_master_default_subdomain:-my.openshift.master.default.subdomain}"
if [ -z "$openshift_master_default_subdomain" ]
then
  echo "Enter the value of openshift_master_default_subdomain: "
  read openshift_master_default_subdomain
fi


### Istio ###

oc adm policy add-scc-to-user anyuid -z istio-ingress-service-account -n istio-system
oc adm policy add-scc-to-user anyuid -z default -n istio-system
oc adm policy add-scc-to-user anyuid -z prometheus -n istio-system
oc adm policy add-scc-to-user anyuid -z istio-egressgateway-service-account -n istio-system
oc adm policy add-scc-to-user anyuid -z istio-citadel-service-account -n istio-system
oc adm policy add-scc-to-user anyuid -z istio-ingressgateway-service-account -n istio-system
oc adm policy add-scc-to-user anyuid -z istio-cleanup-old-ca-service-account -n istio-system
oc adm policy add-scc-to-user anyuid -z istio-mixer-post-install-account -n istio-system
oc adm policy add-scc-to-user anyuid -z istio-mixer-service-account -n istio-system
oc adm policy add-scc-to-user anyuid -z istio-pilot-service-account -n istio-system
oc adm policy add-scc-to-user anyuid -z istio-sidecar-injector-service-account -n istio-system
oc adm policy add-cluster-role-to-user cluster-admin -z istio-galley-service-account -n istio-system
oc adm policy add-scc-to-user anyuid -z cluster-local-gateway-service-account -n istio-system

ISTIO_ARCH=linux
ISTIO_VERSION=1.1.7

curl -L https://github.com/istio/istio/releases/download/$ISTIO_VERSION/istio-$ISTIO_VERSION-$ISTIO_ARCH.tar.gz | tar -zxf -
cd istio-$ISTIO_VERSION
for i in install/kubernetes/helm/istio-init/files/crd*yaml; do kubectl apply -f $i; done
oc apply -f install/kubernetes/istio-demo.yaml
cd ..
rm -Rf istio-$ISTIO_VERSION

### Kabanero ###

namespace=kabanero
oc new-project ${namespace} || true
oc apply -f https://github.com/kabanero-io/kabanero-operator/releases/download/${KABANERO_BRANCH}/kabanero-operators.yaml

# Grant kabanero SA cluster-admin in order to create Appsody SA cluster-admin from the Collection
oc adm policy add-cluster-role-to-user cluster-admin -z kabanero-operator -n ${namespace}

# Create instance, and apply default collections
oc apply -n ${namespace} -f https://raw.githubusercontent.com/kabanero-io/kabanero-operator/${KABANERO_BRANCH}/config/samples/full.yaml


# Need to check KNative Serving CRD is available before proceeding #
until oc get crd services.serving.knative.dev 
do
  sleep 1
done


### Tekton Dashboard ###

# Manual install, pending inclusion to operator
# https://github.com/openshift/tektoncd-pipeline-operator/pull/23
# https://github.com/openshift/tektoncd-pipeline-operator/pull/24

# Wait for tekton CRDs #
until oc get crd clustertasks.tekton.dev config.operator.tekton.dev pipelineresources.tekton.dev pipelineruns.tekton.dev pipelines.tekton.dev taskruns.tekton.dev tasks.tekton.dev
do
  sleep 5
done

release=v0.1.1

# Webhook Extension #
curl -L https://github.com/tektoncd/dashboard/releases/download/${release}/webhooks-extension_release.yaml \
  | sed 's/namespace: tekton-pipelines/namespace: kabanero/' \
  | sed 's/value: tekton-pipelines/value: kabanero/' \
  | oc apply --filename -

# Dashboard #
curl -L https://github.com/tektoncd/dashboard/releases/download/${release}/release.yaml \
  | sed 's/namespace: tekton-pipelines/namespace: kabanero/' \
  | sed 's/default: tekton-pipelines/default: kabanero/' \
  | oc apply --filename -
  
  
# Patch Dashboard #
# https://github.com/tektoncd/dashboard/issues/364
until oc get clusterrole tekton-dashboard-minimal
do
  sleep 1
done
oc patch clusterrole tekton-dashboard-minimal --type json -p='[{"op":"add","path":"/rules/-","value":{"apiGroups":["security.openshift.io"],"resources":["securitycontextconstraints"],"verbs":["use"]}}]'
oc scale -n kabanero deploy tekton-dashboard --replicas=0
sleep 5
oc scale -n kabanero deploy tekton-dashboard --replicas=1


# Kserving Configuration #
oc patch configmap config-domain --namespace knative-serving --type='json' --patch '[{"op": "add", "path": "/data/'"${openshift_master_default_subdomain}"'", "value": ""}]'


### Routes ###

# Expose tekton dashboard with a Route #
until oc get -n kabanero svc tekton-dashboard
do
  sleep 1
done

oc delete route -n kabanero tekton-dashboard || true
oc expose service tekton-dashboard \
  -n kabanero \
  --name "tekton-dashboard" \
  --port="http" \
  --hostname=tekton-dashboard.${openshift_master_default_subdomain}


# Wait for tekton CRDs #
until oc get crd extensions.dashboard.tekton.dev
do
  sleep 5
done

