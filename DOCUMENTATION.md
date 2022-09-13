# EAP Clustering with JGroups on OpenShift

This guide describes how to configure application clustering on EAP deployed within OpenShift 4.x using JGroups.  The EAP images provided by Red Hat can be configured via a [number of environment variables to enable clustering](https://access.redhat.com/documentation/en-us/red_hat_jboss_enterprise_application_platform/7.4/html/getting_started_with_jboss_eap_for_openshift_container_platform/reference_information#configuring_a_jgroups_discovery_mechanism). This guide assumes Red Hat images (or derived images) are used as the basis for configuration. The preferred approach (for security reasons) is to enable encryption of the clustering traffic.  These directions describe first how to configure clustering without encryption and then the additional steps to enable encryption.  

> **_NOTE:_**  If the application has not previously been deployed in a clustered environment, some code changes may be required to support the clustering configuration. This should be taken into consideration when estimating the level of effort.

**Follow these steps to implement clustering:**

1. Review the [Application Requirements](#application-requirements)
2. Follow the [Initial Clustering Configuration](#initial-clustering-configuration) section, including testing the application functionality and retrofitting the code as necessary
3. Follow the [Configuration with Encryption](#configuration-with-encryption) section
5. Be sure to completely undeploy and redeploy the application using the updated templates
4. Run regression tests and verify application functionality
6. 🎉 Celebrate 🎉

## Application Requirements

To take advantage of clustering the Java application must:
* Use a session state-saving technology such as [JEE Stateful Session Beans](https://docs.oracle.com/javaee/7/tutorial/ejb-intro002.htm).
* Specify the `</distributable>` tag within the web.xml file, e.g.

    ```
    <?xml version="1.0"?>
    <web-app xmlns="http://java.sun.com/xml/ns/javaee" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://java.sun.com/xml/ns/javaee http://java.sun.com/xml/ns/javaee/web-app_3_0.xsd" version="3.0">
        <distributable/>
    </web-app>
    ```

## Initial Clustering Configuration

The following environment variables will need to be set on the [Deployment object](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) to enable clustering:

|Environment Variable    |Value                 |Description         |
|------------------------|----------------------|--------------------|
|JGROUPS_PING_PROTOCOL   |kubernetes.KUBE_PING  | This value enables a kubernetes specific protocol for clustering within OpenShift|
|KUBERNETES_NAMESPACE    |*app namespace*       | The namespace where your application will be running. This value can be auto populated within an OpenShift template (shown below in step 1)|
|KUBERNETES_LABELS       |cluster=appname       | replace `appname` with the name of your applications. This same label will need to be added to your deployment object as described below.|
|JGROUPS_CLUSTER_PASSWORD|*password_here*       | A password for the cluster, used by all pods clustered together. This password can be generated within an OpenShift template|

Since OpenShift templates are being used to deploy applications, the template can be updated with the required to make all the required configurations:

1. Update the deployment object within the template to include the required environment variables, update the number of replicas and set labels:

    ```yaml
    ...
    objects:
    ...
    - apiVersion: apps/v1
    kind: Deployment
    ...
    spec:
      replicas: 2 # Update the number of replicas to at least 2
    ...
      template:
        metadata:
        ...
          labels:
            cluster: appname
        ...
        spec:
            containers:
            ...
              env:
              - name: JGROUPS_CLUSTER_PASSWORD
                value: ${JGROUPS_PASSWORD}
              - name: JGROUPS_PING_PROTOCOL
                value: kubernetes.KUBE_PING
              - name: KUBERNETES_LABELS
                value: cluster=appname
              - name: KUBERNETES_NAMESPACE
                valueFrom:
                  fieldRef:
                      fieldPath: metadata.namespace
    ...
    parameters:
    ...
    - name: JGROUPS_PASSWORD
      description: Randomly generated password for the JGroups Cluster
      generate: expression
      from: '[a-zA-Z0-9]{8}'
      required: true
    ```

2. Deploy the application, as usual, using the template and you should observe the following in the logs:

    ```
    INFO Configuring JGroups cluster traffic encryption protocol to SYM_ENCRYPT.
    WARN Detected missing JGroups encryption configuration, the communication within the cluster WILL NOT be encrypted.
    INFO Service account has sufficient permissions to view pods in kubernetes (HTTP 200). Clustering will be available.
    INFO Configuring JGroups discovery protocol to kubernetes.KUBE_PING
    ...
    ...
    ...
    18:12:55,745 INFO  [org.infinispan.CLUSTER] (ServerService Thread Pool -- 78) ISPN000078: Starting JGroups channel ee
    18:12:55,751 INFO  [org.infinispan.CLUSTER] (ServerService Thread Pool -- 76) ISPN000094: Received new cluster view for channel ee: [...
    18:12:55,756 INFO  [org.infinispan.CLUSTER] (ServerService Thread Pool -- 76) ISPN000079: Channel ee local address is ...
    ```

3. Verify there are no JGroups or Infinispan related errors in the logs.  If there are errors, verify that you have configured the deployment object correctly.  If so, reach out to a member of the application migration team.

4. Once the pod instances are up, exercise the application such that the state has been recorded (e.g., login to the application). Determine which pod has been called by your test and bring it down.  Refresh the application and verify the state was successfully restored (e.g., the user is still logged in).  You will need to test all the stateful aspects of your application to verify it is behaving as expected

Verify there were no serialization-related errors when switching pods.  If you have errors related to serialization, you will need to update your code to make sure none of your stateful session beans have attributes that are not serializable. In some cases, the fix is as simple as marking the attribute as `transient`. In other cases, you may need to make the attribute serializable or reconstruct the object if you find it is null.  This is purely a function of the state requirements of the application.

5. Run any existing regression tests on the application to verify application behavior.


## Configuration with Encryption

> **_NOTE:_**  These directions currently disable FIPS enforcement in OpenJDK 11+ and will be updated to be compliant once a working solution has been prototyped successfully.

1. First complete the steps described in [the previous section](#initial-clustering-configuration)
2. Create a keystore to be used for encrypting clustering traffic. The following OpenShift commands can be used to create the keystore file and add it as a secret to the application namespace ([reference documentation]( https://access.redhat.com/documentation/en-us/red_hat_jboss_enterprise_application_platform/7.0/html/configuration_guide/configuring_high_availability#securing_cluste))

    > **_NOTE:_**  In the future, the keystore and its associatied information will be provided by the ECP team and these steps will no longer be necessary.

    ```bash
    # Verify you are in the correct OpenShift namespace for the application, e.g. "oc status"

    # Point the EAP_IMAGE environment variable to a valid location of an EAP image
    # (this could also be the application image in the namespace)
    export EAP_IMAGE=image-registry.openshift-image-registry.svc:5000/openshift/jboss-eap74-openjdk11-openshift

    # Set a password for the keystore
    export KEYSTORE_PASSWORD=SecurePassword123

    # Create a temporary pod. We will run commands in this pod to create the Java key store.
    oc run eap-temp --env=JDK_JAVA_OPTIONS='-Dcom.redhat.fips=false' --image=$EAP_IMAGE --command -- sleep 86400

    # Wait for the temporary pod to be ready
    oc wait --for=condition=Ready pod/eap-temp

    # Execute a java command in the temporary pod to generate the keystore. 
    # Note: the location of the jar file may change as the EAP release updates so update as necessary
    oc exec eap-temp -- java -cp \
      /opt/jboss/container/wildfly/s2i/galleon/galleon-m2-repository/org/jgroups/jgroups/4.2.15.Final-redhat-00001/jgroups-4.2.15/Final-redhat-00001.jar \
      org.jgroups.demos.KeyStoreGenerator --alg AES --size 128 --storeName /tmp/jgroups.keystore \
      --storepass $KEYSTORE_PASSWORD --alias jgroups

    # Copy the keystore out of the temporary container into the current local directory
    oc cp eap-temp:/tmp/jgroups.keystore ./jgroups.keystore

    # Delete the temporary pod
    oc delete pod --now eap-temp
    
    # Create a secret that contains the keystore file
    oc create secret generic eap-clustering --from-file=jgroups.keystore
    ```

3. Next, add the following environment variables to the deployment definition in the template. Update the volume and volume mounts as well (details below):


    |Environment Variable        |Value                             |Description         |
    |----------------------------|----------------------------------|--------------------|
    |JGROUPS_ENCRYPT_PROTOCOL    |SYM_ENCRYPT                       |Enable symmetric Encryption|
    |JGROUPS_ENCRYPT_PASSWORD    |*SecurePassword123*               |Set to the keystore password|
    |JGROUPS_ENCRYPT_SECRET      |eap-clustering                    |OpenShift secret object containing the keystore|
    |JGROUPS_ENCRYPT_KEYSTORE    |jgroups.keystore                  |The name of the keystore file|
    |JGROUPS_ENCRYPT_KEYSTORE_DIR|/etc/jgroups-encrypt-secret-volume|Directory on the pod containing the keystore file|
    |JGROUPS_ENCRYPT_NAME        |jgroups                           |The keystore alias associated with the key|
    
    ```yaml
    ...
    objects:
    ...
    - apiVersion: apps/v1
      kind: Deployment
      ...
      spec:
        replicas: 2 # Update the number of replicas to at least 2
      ...
        template:
          metadata:
          ...
            labels:
              cluster: appname
          ...
          spec:
              containers:
              ...
                env:
                ...
                - name: JGROUPS_ENCRYPT_PROTOCOL
                  value: SYM_ENCRYPT
                - name: JGROUPS_ENCRYPT_PASSWORD
                  value: SecurePassword123
                - name: JGROUPS_ENCRYPT_SECRET
                  value: eap-clustering
                - name: JGROUPS_ENCRYPT_KEYSTORE
                  value: jgroups.keystore
                - name: JGROUPS_ENCRYPT_KEYSTORE_DIR
                  value: /etc/jgroups-encrypt-secret-volume
                - name: JGROUPS_ENCRYPT_NAME
                  value: jgroups
                ...
                volumeMounts:
                - mountPath: /etc/jgroups-encrypt-secret-volume
                  name: secretkey
                ...
              volumes:
              - name: secretkey
                secret:
                  secretName: eap-clustering

    ...
    ```
4. Deploy the application, as usual, using the template and you should observe the following in the logs:

    ```
    INFO Configuring JGroups cluster traffic encryption protocol to SYM_ENCRYPT.
    INFO Service account has sufficient permissions to view pods in kubernetes (HTTP 200). Clustering will be available.
    INFO Configuring JGroups discovery protocol to kubernetes.KUBE_PING
    ...
    ...
    ...
    18:12:55,745 INFO  [org.infinispan.CLUSTER] (ServerService Thread Pool -- 78) ISPN000078: Starting JGroups channel ee
    18:12:55,751 INFO  [org.infinispan.CLUSTER] (ServerService Thread Pool -- 76) ISPN000094: Received new cluster view for channel ee: [...
    18:12:55,756 INFO  [org.infinispan.CLUSTER] (ServerService Thread Pool -- 76) ISPN000079: Channel ee local address is ...
    ```

5. Verify this warning no longer appears in the logs:
  ```
      WARN Detected missing JGroups encryption configuration, the communication within the cluster WILL NOT be encrypted.
  ```

6. Verify there are no JGroups or infinispan related errors in the logs.  If there are errors, verify that you have configured the deployment object correctly.  If you have and there are still errors, reach out to a member of the application migration team.

