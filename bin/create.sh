#!/bin/bash

# https://github.com/openshift/installer/blob/master/docs/user/gcp/install_upi.md

topdir="$(cd $(dirname "${BASH_SOURCE[0]}") && pwd -P)"/..

: ${OPENSHIFT_INSTALLER_DIR:=$topdir/installer}
: ${HATTER_NAME:?}

if [ ! -x ./openshift-install ]; then
    echo "Need local openshift-install binary"
    exit 1
fi

if [ ! -f $topdir/installer/upi/gcp/01_vpc.py ]; then
    echo "Did you run: git submodule update --init"
    exit 1
fi

set -eu

export GOOGLE_CREDENTIALS=~/.secrets/aos-serviceaccount.json

./openshift-install version

gcloud auth activate-service-account --key-file $GOOGLE_CREDENTIALS

# Create an install configuration as per the usual approach.
./openshift-install create install-config

# Empty the compute pool (optional)
# python3 -c '
# import yaml;
# path = "install-config.yaml";
# data = yaml.full_load(open(path));
# data["compute"][0]["replicas"] = 1;
# open(path, "w").write(yaml.dump(data, default_flow_style=False))'

# Create manifest to enable customizations which are not exposed via the install configuration.
./openshift-install create manifests

# Remove control plane machines
#
# Remove the control plane machines from the manifests. We'll be
# providing those ourselves and don't want to involve the machine-API
# operator.
rm -f openshift/99_openshift-cluster-api_master-machines-*.yaml

# Remove compute machinesets (Optional)
#
# If you do not want the cluster to provision compute machines, remove
# the compute machinesets from the manifests as well.
# rm -f openshift/99_openshift-cluster-api_worker-machineset-*.yaml

# Make control-plane nodes unschedulable
python -c '
import yaml;
path = "manifests/cluster-scheduler-02-config.yml"
data = yaml.load(open(path));
data["spec"]["mastersSchedulable"] = False;
open(path, "w").write(yaml.dump(data, default_flow_style=False))'

# Remove DNS Zones (Optional)
#
# If you don't want the ingress operator to create DNS records on your
# behalf, remove the privateZone and publicZone sections from the DNS
# configuration. If you do so, you'll need to add ingress DNS records
# manually later on.
#
# python -c '
# import yaml;
# path = "manifests/cluster-dns-02-config.yml";
# data = yaml.full_load(open(path));
# del data["spec"]["publicZone"];
# del data["spec"]["privateZone"];
# open(path, "w").write(yaml.dump(data, default_flow_style=False))'

# Create Ignition configs
./openshift-install create ignition-configs

# Extract infrastructure name from Ignition metadata
export BASE_DOMAIN='gcp.devcluster.openshift.com'
export BASE_DOMAIN_ZONE_NAME="devcluster"
export NETWORK_CIDR='10.0.0.0/16'
export MASTER_SUBNET_CIDR='10.0.0.0/19'
export WORKER_SUBNET_CIDR='10.0.32.0/19'

export KUBECONFIG=$PWD/auth/kubeconfig
export CLUSTER_NAME=`jq -r .clusterName metadata.json`
export INFRA_ID=`jq -r .infraID metadata.json`
export PROJECT_NAME=`jq -r .gcp.projectID metadata.json`
export REGION=`jq -r .gcp.region metadata.json`

# Create the VPC
cp ${OPENSHIFT_INSTALLER_DIR}/upi/gcp/01_vpc.py .
cat <<EOF >01_vpc.yaml
imports:
- path: 01_vpc.py
resources:
- name: cluster-vpc
  type: 01_vpc.py
  properties:
    infra_id: '${INFRA_ID}'
    region: '${REGION}'

    master_subnet_cidr: '${MASTER_SUBNET_CIDR}'
    worker_subnet_cidr: '${WORKER_SUBNET_CIDR}'
EOF

# Create the deployment using gcloud.
gcloud deployment-manager deployments create ${INFRA_ID}-vpc --config 01_vpc.yaml

# Create DNS entries and load balancers
# Export variables needed by the resource definition.
# Create a resource definition file: 02_infra.yaml
export CLUSTER_NETWORK=`gcloud compute networks describe ${INFRA_ID}-network --format json | jq -r .selfLink`

cp ${OPENSHIFT_INSTALLER_DIR}/upi/gcp/02_infra.py .
cat <<EOF >02_infra.yaml
imports:
- path: 02_infra.py

resources:
- name: cluster-infra
  type: 02_infra.py
  properties:
    infra_id: '${INFRA_ID}'
    region: '${REGION}'

    cluster_domain: '${CLUSTER_NAME}.${BASE_DOMAIN}'
    cluster_network: '${CLUSTER_NETWORK}'
EOF

# Create the deployment using gcloud.
gcloud deployment-manager deployments create ${INFRA_ID}-infra --config 02_infra.yaml

# The templates do not create DNS entries due to limitations of
# Deployment Manager, so we must create them manually.
export CLUSTER_IP=`gcloud compute addresses describe ${INFRA_ID}-cluster-public-ip --region=${REGION} --format json | jq -r .address`

# Add external DNS entries
if [ -f transaction.yaml ]; then rm transaction.yaml; fi
gcloud dns record-sets transaction start --zone ${BASE_DOMAIN_ZONE_NAME}
gcloud dns record-sets transaction add ${CLUSTER_IP} --name api.${CLUSTER_NAME}.${BASE_DOMAIN}. --ttl 60 --type A --zone ${BASE_DOMAIN_ZONE_NAME}
gcloud dns record-sets transaction execute --zone ${BASE_DOMAIN_ZONE_NAME}

# Add internal DNS entries
if [ -f transaction.yaml ]; then rm transaction.yaml; fi
gcloud dns record-sets transaction start --zone ${INFRA_ID}-private-zone
gcloud dns record-sets transaction add ${CLUSTER_IP} --name api.${CLUSTER_NAME}.${BASE_DOMAIN}. --ttl 60 --type A --zone ${INFRA_ID}-private-zone
gcloud dns record-sets transaction add ${CLUSTER_IP} --name api-int.${CLUSTER_NAME}.${BASE_DOMAIN}. --ttl 60 --type A --zone ${INFRA_ID}-private-zone
gcloud dns record-sets transaction execute --zone ${INFRA_ID}-private-zone

# Create firewall rules and IAM roles
export MASTER_NAT_IP=`gcloud compute addresses describe ${INFRA_ID}-master-nat-ip --region ${REGION} --format json | jq -r .address`
export WORKER_NAT_IP=`gcloud compute addresses describe ${INFRA_ID}-worker-nat-ip --region ${REGION} --format json | jq -r .address`

cp ${OPENSHIFT_INSTALLER_DIR}/upi/gcp/03_security.py .
cat <<EOF >03_security.yaml
imports:
- path: 03_security.py

resources:
- name: cluster-security
  type: 03_security.py
  properties:
    infra_id: '${INFRA_ID}'
    region: '${REGION}'

    cluster_network: '${CLUSTER_NETWORK}'
    network_cidr: '${NETWORK_CIDR}'
    master_nat_ip: '${MASTER_NAT_IP}'
    worker_nat_ip: '${WORKER_NAT_IP}'
EOF

# Create the deployment using gcloud.
gcloud deployment-manager deployments create ${INFRA_ID}-security --config 03_security.yaml

# The templates do not create the policy bindings due to limitations
# of Deployment Manager, so we must create them manually.
export MASTER_SA=${INFRA_ID}-m@${PROJECT_NAME}.iam.gserviceaccount.com
gcloud projects add-iam-policy-binding ${PROJECT_NAME} --member "serviceAccount:${MASTER_SA}" --role "roles/compute.instanceAdmin"
gcloud projects add-iam-policy-binding ${PROJECT_NAME} --member "serviceAccount:${MASTER_SA}" --role "roles/compute.networkAdmin"
gcloud projects add-iam-policy-binding ${PROJECT_NAME} --member "serviceAccount:${MASTER_SA}" --role "roles/compute.securityAdmin"
gcloud projects add-iam-policy-binding ${PROJECT_NAME} --member "serviceAccount:${MASTER_SA}" --role "roles/iam.serviceAccountUser"
gcloud projects add-iam-policy-binding ${PROJECT_NAME} --member "serviceAccount:${MASTER_SA}" --role "roles/storage.admin"

## Added by me
gcloud projects add-iam-policy-binding ${PROJECT_NAME} --member "serviceAccount:${MASTER_SA}" --role "roles/iam.serviceAccountKeyAdmin"

export WORKER_SA=${INFRA_ID}-w@${PROJECT_NAME}.iam.gserviceaccount.com
gcloud projects add-iam-policy-binding ${PROJECT_NAME} --member "serviceAccount:${WORKER_SA}" --role "roles/compute.viewer"
gcloud projects add-iam-policy-binding ${PROJECT_NAME} --member "serviceAccount:${WORKER_SA}" --role "roles/storage.admin"

# Create a service account key and store it locally for later use.

# XXXX
# 
# I have to switch my account back to ${HATTER_NAME}@redhat.com for
# this to work.
#
# Pre Mon 18 Nov 2019 11:54:40 AM GMT
# gcloud config set account amcdermo@redhat.com
# gcloud iam service-accounts keys create service-account-key.json --iam-account=${MASTER_SA}
# gcloud auth activate-service-account --key-file $GOOGLE_CREDENTIALS

# Post Mon 18 Nov 2019 11:54:40 AM GMT

gcloud --account=${HATTER_NAME}@redhat.com iam service-accounts keys create service-account-key.json --iam-account=${MASTER_SA}

# Create the cluster image.
export IMAGE_SOURCE=`curl https://raw.githubusercontent.com/openshift/installer/master/data/data/rhcos.json | jq -r .gcp.url`
gcloud compute images create "${INFRA_ID}-rhcos-image" --source-uri="${IMAGE_SOURCE}"

# Launch temporary bootstrap resources
export CONTROL_SUBNET=`gcloud compute networks subnets describe ${INFRA_ID}-master-subnet --region=${REGION} --format json | jq -r .selfLink`
export CLUSTER_IMAGE=`gcloud compute images describe ${INFRA_ID}-rhcos-image --format json | jq -r .selfLink`
export ZONE_0=`gcloud compute regions describe ${REGION} --format=json | jq -r .zones[0] | cut -d "/" -f9`
export ZONE_1=`gcloud compute regions describe ${REGION} --format=json | jq -r .zones[1] | cut -d "/" -f9`
export ZONE_2=`gcloud compute regions describe ${REGION} --format=json | jq -r .zones[2] | cut -d "/" -f9`

# Create a bucket and upload the bootstrap.ign file.
gsutil mb gs://${INFRA_ID}-bootstrap-ignition
gsutil cp bootstrap.ign gs://${INFRA_ID}-bootstrap-ignition/

# Create a signed URL for the bootstrap instance to use to access the
# Ignition config. Export the URL from the output as a variable.
export BOOTSTRAP_IGN=`gsutil signurl -d 1h service-account-key.json gs://${INFRA_ID}-bootstrap-ignition/bootstrap.ign | grep "^gs:" | awk '{print $5}'`

# Create a resource definition file: 04_bootstrap.yaml
cp ${OPENSHIFT_INSTALLER_DIR}/upi/gcp/04_bootstrap.py .
cat <<EOF >04_bootstrap.yaml
imports:
- path: 04_bootstrap.py

resources:
- name: cluster-bootstrap
  type: 04_bootstrap.py
  properties:
    infra_id: '${INFRA_ID}'
    region: '${REGION}'
    zone: '${ZONE_0}'

    cluster_network: '${CLUSTER_NETWORK}'
    control_subnet: '${CONTROL_SUBNET}'
    image: '${CLUSTER_IMAGE}'
    machine_type: 'n1-standard-4'
    root_volume_size: '128'

    bootstrap_ign: '${BOOTSTRAP_IGN}'
EOF

# Create the deployment using gcloud.
gcloud deployment-manager deployments create ${INFRA_ID}-bootstrap --config 04_bootstrap.yaml

# The templates do not manage load balancer membership due to
# limitations of Deployment Manager, so we must add the bootstrap node
# manually.
gcloud compute target-pools add-instances ${INFRA_ID}-api-target-pool --instances-zone="${ZONE_0}" --instances=${INFRA_ID}-bootstrap
gcloud compute target-pools add-instances ${INFRA_ID}-ign-target-pool --instances-zone="${ZONE_0}" --instances=${INFRA_ID}-bootstrap

# Export variables needed by the resource definition.
export MASTER_SERVICE_ACCOUNT_EMAIL=`gcloud iam service-accounts list | grep "^${INFRA_ID}-master-node " | awk '{print $2}'`
export MASTER_IGNITION=`cat master.ign`

# Create a resource definition file: 05_control_plane.yaml
cp ${OPENSHIFT_INSTALLER_DIR}/upi/gcp/05_control_plane.py .
cat <<EOF >05_control_plane.yaml
imports:
- path: 05_control_plane.py

resources:
- name: cluster-control-plane
  type: 05_control_plane.py
  properties:
    infra_id: '${INFRA_ID}'
    region: '${REGION}'
    zones:
    - '${ZONE_0}'
    - '${ZONE_1}'
    - '${ZONE_2}'

    control_subnet: '${CONTROL_SUBNET}'
    image: '${CLUSTER_IMAGE}'
    machine_type: 'n1-standard-4'
    root_volume_size: '128'
    service_account_email: '${MASTER_SERVICE_ACCOUNT_EMAIL}'

    ignition: '${MASTER_IGNITION}'
EOF

# Create the deployment using gcloud.
gcloud deployment-manager deployments create ${INFRA_ID}-control-plane --config 05_control_plane.yaml

# The templates do not manage DNS entries due to limitations of
# Deployment Manager, so we must add the etcd entries manually.
export MASTER0_IP=`gcloud compute instances describe ${INFRA_ID}-m-0 --zone ${ZONE_0} --format json | jq -r .networkInterfaces[0].networkIP`
export MASTER1_IP=`gcloud compute instances describe ${INFRA_ID}-m-1 --zone ${ZONE_1} --format json | jq -r .networkInterfaces[0].networkIP`
export MASTER2_IP=`gcloud compute instances describe ${INFRA_ID}-m-2 --zone ${ZONE_2} --format json | jq -r .networkInterfaces[0].networkIP`
if [ -f transaction.yaml ]; then rm transaction.yaml; fi
gcloud dns record-sets transaction start --zone ${INFRA_ID}-private-zone
gcloud dns record-sets transaction add ${MASTER0_IP} --name etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}. --ttl 60 --type A --zone ${INFRA_ID}-private-zone
gcloud dns record-sets transaction add ${MASTER1_IP} --name etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}. --ttl 60 --type A --zone ${INFRA_ID}-private-zone
gcloud dns record-sets transaction add ${MASTER2_IP} --name etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}. --ttl 60 --type A --zone ${INFRA_ID}-private-zone
gcloud dns record-sets transaction add \
       "0 10 2380 etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}." \
       "0 10 2380 etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}." \
       "0 10 2380 etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}." \
       --name _etcd-server-ssl._tcp.${CLUSTER_NAME}.${BASE_DOMAIN}. --ttl 60 --type SRV --zone ${INFRA_ID}-private-zone
gcloud dns record-sets transaction execute --zone ${INFRA_ID}-private-zone

# The templates do not manage load balancer membership due to
# limitations of Deployment Manager, so we must add the control plane
# nodes manually.
gcloud compute target-pools add-instances ${INFRA_ID}-api-target-pool --instances-zone="${ZONE_0}" --instances=${INFRA_ID}-m-0
gcloud compute target-pools add-instances ${INFRA_ID}-api-target-pool --instances-zone="${ZONE_1}" --instances=${INFRA_ID}-m-1
gcloud compute target-pools add-instances ${INFRA_ID}-api-target-pool --instances-zone="${ZONE_2}" --instances=${INFRA_ID}-m-2
gcloud compute target-pools add-instances ${INFRA_ID}-ign-target-pool --instances-zone="${ZONE_0}" --instances=${INFRA_ID}-m-0
gcloud compute target-pools add-instances ${INFRA_ID}-ign-target-pool --instances-zone="${ZONE_1}" --instances=${INFRA_ID}-m-1
gcloud compute target-pools add-instances ${INFRA_ID}-ign-target-pool --instances-zone="${ZONE_2}" --instances=${INFRA_ID}-m-2

# Deploy compute
export COMPUTE_SUBNET=`gcloud compute networks subnets describe ${INFRA_ID}-worker-subnet --region=${REGION} --format json | jq -r .selfLink`
export WORKER_SERVICE_ACCOUNT_EMAIL=`gcloud iam service-accounts list | grep "^${INFRA_ID}-worker-node " | awk '{print $2}'`
export WORKER_IGNITION=`cat worker.ign`
export ZONES=(`gcloud compute regions describe ${REGION} --format=json | jq -r .zones[] | cut -d "/" -f9`)

cp ${OPENSHIFT_INSTALLER_DIR}/upi/gcp/06_worker.py .
cat <<EOF >06_worker.yaml
imports:
- path: 06_worker.py
resources:
EOF

for compute in {0..2}; do
    cat <<EOF >>06_worker.yaml
- name: 'w-${compute}'
  type: 06_worker.py
  properties:
    infra_id: '${INFRA_ID}'
    region: '${REGION}'
    zone: '${ZONES[(( $compute % ${#ZONES[@]} ))]}'

    compute_subnet: '${COMPUTE_SUBNET}'
    image: '${CLUSTER_IMAGE}'
    machine_type: 'n1-standard-4'
    root_volume_size: '128'
    service_account_email: '${WORKER_SERVICE_ACCOUNT_EMAIL}'

    ignition: '${WORKER_IGNITION}'
EOF
done

gcloud deployment-manager deployments create ${INFRA_ID}-worker --config 06_worker.yaml

# Monitor for bootstrap-complete
./openshift-install --log-level=debug wait-for bootstrap-complete

# Destroy bootstrap resources
gcloud compute target-pools remove-instances ${INFRA_ID}-api-target-pool --instances-zone="${ZONE_0}" --instances=${INFRA_ID}-bootstrap
gcloud compute target-pools remove-instances ${INFRA_ID}-ign-target-pool --instances-zone="${ZONE_0}" --instances=${INFRA_ID}-bootstrap
gsutil rm gs://${INFRA_ID}-bootstrap-ignition/bootstrap.ign
gsutil rb gs://${INFRA_ID}-bootstrap-ignition
gcloud deployment-manager deployments delete ${INFRA_ID}-bootstrap -q

# Approve compute nodes, if not already
for compute in {0..2}; do
    $topdir/bin/approvecsr.sh ${INFRA_ID}-w-${compute}
done;

# Add wildcard dns record for *.apps
export ROUTER_IP=''
while [[ "$ROUTER_IP" == "" || "$ROUTER_IP" == "<pending>" ]]; do
    export ROUTER_IP=`oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}'`
    sleep 10;
    echo $ROUTER_IP
done

### Why has this just started to fail? (Mon 18 Nov 17:40:31 GMT 2019)

set +e

if [ -f transaction.yaml ]; then rm transaction.yaml; fi
gcloud dns record-sets transaction start --zone ${BASE_DOMAIN_ZONE_NAME}
gcloud dns record-sets transaction add ${ROUTER_IP} --name \*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}. --ttl 300 --type A --zone ${BASE_DOMAIN_ZONE_NAME}
gcloud dns record-sets transaction execute --zone ${BASE_DOMAIN_ZONE_NAME}

if [ -f transaction.yaml ]; then rm transaction.yaml; fi
gcloud dns record-sets transaction start --zone ${INFRA_ID}-private-zone
gcloud dns record-sets transaction add ${ROUTER_IP} --name \*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}. --ttl 300 --type A --zone ${INFRA_ID}-private-zone
gcloud dns record-sets transaction execute --zone ${INFRA_ID}-private-zone

set -e

./openshift-install --log-level=debug wait-for install-complete
