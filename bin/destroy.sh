#!/bin/bash

set -x

if [ ! -f metadata.json ]; then exit 1; fi
export INFRA_ID=`jq -r .infraID metadata.json`

if [ -z $INFRA_ID ]; then exit 2; fi

# Use openshift-install to delete the cluster.
./openshift-install destroy cluster

# Delete the deployments
gcloud -q deployment-manager deployments delete \
       ${INFRA_ID}-worker \
       ${INFRA_ID}-control-plane \
       ${INFRA_ID}-bootstrap \
       ${INFRA_ID}-security \
       ${INFRA_ID}-infra \
       ${INFRA_ID}-vpc

rm -f .openshift_install.log
rm -f *.yaml
rm -f *.ign
rm -f service-account-key.json
