#!/bin/bash

EAP_IMAGE=image-registry.openshift-image-registry.svc:5000/openshift/jboss-eap74-openjdk11-openshift
EAP_IMAGE_STREAM=jboss-eap74-openjdk11-openshift:latest
KEYSTORE_PASSWORD=PASSWORD

oc new-project eap-no-fips

#############################
# Deploy Clustered EAP Pods #
#############################
oc new-build --name eap-clustering https://github.com/kharyam/eap74-cluster-test.git -i $EAP_IMAGE_STREAM
build_exists=1

echo -n Waiting for build
while [ $build_exists != 0 ]
do
  echo -n .
  sleep 1
  oc get pods | grep eap-clustering-1-build | grep Running
  build_exists=$?
done

oc logs -f eap-clustering-1-build

oc policy add-role-to-user view -z default -n $(oc project -q)

oc new-app --name eap-clustering -i eap-clustering -e JGROUPS_PING_PROTOCOL=kubernetes.KUBE_PING -e KUBERNETES_NAMESPACE=$(oc project -q) -e KUBERNETES_LABELS=cluster=group1 -e JGROUPS_CLUSTER_PASSWORD=jgroupsclusterpassword -l cluster=group1

# Create 2 pods
oc patch deployment/eap-clustering -p '{"spec": {"replicas" : 2 } }'

oc create route edge --service eap-clustering

