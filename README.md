Scripts to standup a UPI-based OpenShift cluster (on GCP)

## Prerequisites

This relies on files from the openshift installer repo:

	$ git submodule update --init

Find a (nightly
build)[https://openshift-release.svc.ci.openshift.org/] that is green,
download the installer, extract and make sure that the `openshift-install`
binary exists.

## Verify version

	./openshift-install version

## Create a cluster

Standup a cluster:

	./create.sh

##

Destroy the cluster

	./destroy.sh
