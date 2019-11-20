#!/bin/bash

set -x

if [ ! -f metadata.json ]; then exit 1; fi
export INFRA_ID=`jq -r .infraID metadata.json`

if [ -z $INFRA_ID ]; then exit 2; fi

# Use openshift-install to delete the cluster.
./openshift-install destroy cluster

# Delete the deployments
for i in worker control-plane bootstrap security infra vpc
do
    gcloud -q deployment-manager deployments delete ${INFRA_ID}-$i
done

rm -f .openshift_install.log
rm -f *.yaml
rm -f *.ign
rm -f service-account-key.json
