Scripts to standup a UPI-based OpenShift cluster (on GCP)

## Prerequisites

This relies on files from the openshift installer repo:

	$ git submodule update --init


# Usage

Find a [nightly][https://openshift-release.svc.ci.openshift.org/] that
is green, download the installer, extract and make sure that the
`openshift-install` binary exists.

```sh
mkdir 4.3.0-0.nightly-2019-11-18-062034
cd 4.3.0-0.nightly-2019-11-18-062034
wget https://openshift-release-artifacts.svc.ci.openshift.org/4.3.0-0.nightly-2019-11-18-062034/openshift-install-linux-4.3.0-0.nightly-2019-11-18-062034.tar.gz
tar xf openshift-install-linux-4.3.0-0.nightly-2019-11-18-062034.tar.gz
```

```
# Create the cluster
../bin/create.sh
```

```
# Once done destroy the cluster
../bin/destroy.sh
```
