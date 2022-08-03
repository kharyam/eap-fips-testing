# eap-fips-testing
Testing EAP compatibility with FIPS enabled on OpenShift 4.x and JDK 11

* **deploy-basic.sh** - Install of a clustered app using jgroups but without encryption enabled (no interference from FIPS)
* **deploy-encryption.sh** - Same as above but with encryption configured for testing in a FIPS enabled OCP Cluater.
