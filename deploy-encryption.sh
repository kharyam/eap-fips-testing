#!/bin/bash

EAP_IMAGE=image-registry.openshift-image-registry.svc:5000/openshift/jboss-eap74-openjdk11-openshift
EAP_IMAGE_STREAM=jboss-eap74-openjdk11-openshift:latest
KEYSTORE_PASSWORD=PASSWORD

oc new-project eap-fips

###############################
# Create keystore for JGroups #
############################### 
oc run eap-temp --env=JDK_JAVA_OPTIONS='-Dcom.redhat.fips=false' --image=$EAP_IMAGE --command -- sleep 86400
echo Waiting for pod...
oc wait --for=condition=Ready pod/eap-temp
oc exec eap-temp -- java -cp /opt/jboss/container/wildfly/s2i/galleon/galleon-m2-repository/org/jgroups/jgroups/4.2.15.Final-redhat-00001/jgroups-4.2.15.Final-redhat-00001.jar org.jgroups.demos.KeyStoreGenerator --alg AES --size 128 --storeName /tmp/jgroups.keystore --storepass $KEYSTORE_PASSWORD --alias jgroups 
oc cp eap-temp:/tmp/jgroups.keystore ./jgroups.keystore
oc delete pod --now eap-temp

oc delete secret eap-clustering
oc create secret generic eap-clustering --from-file=jgroups.keystore

#############################
# Deploy Clustered EAP Pods #
#############################
#oc new-build --name eap-clustering https://github.com/kharyam/eap74-cluster-test.git -i $EAP_IMAGE_STREAM
oc new-build --name eap-clustering https://github.com/kharyam/eap7-cluster-test-app.git#cleanup -i $EAP_IMAGE_STREAM
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

oc new-app --name eap-clustering -i eap-clustering -e JGROUPS_PING_PROTOCOL=kubernetes.KUBE_PING -e KUBERNETES_NAMESPACE=$(oc project -q) -e KUBERNETES_LABELS=cluster=group1 \
   -e JGROUPS_CLUSTER_PASSWORD=jgroupsclusterpassword -e JGROUPS_ENCRYPT_PROTOCOL=SYM_ENCRYPT -e JGROUPS_ENCRYPT_PASSWORD=$KEYSTORE_PASSWORD -e JGROUPS_ENCRYPT_SECRET=eap-clustering \
   -e JGROUPS_ENCRYPT_KEYSTORE=jgroups.keystore -e JGROUPS_ENCRYPT_KEYSTORE_DIR=/etc/jgroups-encrypt-secret-volume -e JGROUPS_ENCRYPT_NAME=jgroups -l cluster=group1

# Create volume for keystore
oc set volume deployment/eap-clustering --type=secret --secret-name=eap-clustering --add --mount-path=/etc/jgroups-encrypt-secret-volume

# Add env var to disable fips
# TODO: Alternatives?
oc set env deployment/eap-clustering JDK_JAVA_OPTIONS='-Dcom.redhat.fips=false'

# Create 2 pods
oc patch deployment/eap-clustering -p '{"spec": {"replicas" : 2 } }'

oc set probe deployment/eap-clustering --readiness --get-url=http://:8080 --liveness --initial-delay-seconds=60 --get-url=http://:8080

oc create route edge --service eap-clustering

