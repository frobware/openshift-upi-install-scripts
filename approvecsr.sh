#!/bin/bash

if [ -z $1 ]; then return 1; fi

echo -n "Approving serviceaccount csr for $1: "
count=0;
loop=0;
while [ $count -lt 1 -a $loop -lt 10 ];
do
    echo -n '.'
    for csr in `oc get csr --no-headers \
    | grep " system:serviceaccount:openshift-machine-config-operator:node-bootstrapper " \
    | cut -d " " -f1`;
    do
	oc describe csr/${csr} \
	    | grep " system:node:${1}\." > /dev/null;
	if [ $? -eq 0 ];
	then
	    oc adm certificate approve ${csr};
	    if [ $? -eq 0 ];
	    then
		count=$((count+1));
	    fi;
	fi;
    done;
    loop=$((loop+1));
    sleep 3;
done;
echo ""

echo -n "Approving node csr for $1: "
count=0;
loop=0;
while [ $count -lt 1 -a $loop -lt 10 ];
do
    for csr in `oc get csr --no-headers \
    | grep " system:node:${1}\." \
    | cut -d " " -f1`;
    do
	oc adm certificate approve ${csr} > /dev/null;
	if [ $? -eq 0 ];
	then
	    count=$((count+1));
	fi;
    done;
    echo -n '.'
    loop=$((loop+1));
    sleep 3;
done;
echo ""
