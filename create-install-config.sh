#!/usr/bin/env bash

function create_gcp_config {
    AUTHS_JSON="$(jq '.auths' $HOME/.secrets/pull-secret.json)"
    SSH_KEY=$(<$HOME/.ssh/id_rsa.pub)  
    cat <<EOF
apiVersion: v1
baseDomain: gcp.devcluster.openshift.com
compute:
- hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 3
controlPlane:
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: 3
metadata:
  creationTimestamp: null
  name: amcdermo
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineCIDR: 10.0.0.0/16
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16
platform:
  gcp:
    projectID: openshift-gce-devel
    region: us-east1
publish: External
pullSecret: '{"auths": ${AUTHS_JSON}}'
sshKey: |
  '${SSH_KEY}'
EOF
}

create_gcp_config
