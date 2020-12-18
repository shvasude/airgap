#!/bin/bash -xe

CATALOG_IMAGE=$CATALOG_IMAGE
CATALOG_USER='redhat'
CATALOG_IMAGE_NAME='redhat-operator-index'
CATALOG_IMAGE_TAG='v4.6'
OUTPUT_IMAGE=$MIRROR_REGISTRY
PRODUCT_NAME=${1:-binding}
CATALOG_SOURCE_NAME='sb-operator-test'

MIRROR_IMAGE_LOCATION=$OUTPUT_IMAGE/$CATALOG_USER/$CATALOG_IMAGE_NAME:$CATALOG_IMAGE_TAG

USER_NAME="dummy"
PASSWORD="dummy"

function mirror_images()
{
  oc image mirror $1 $2 --insecure --keep-manifest-list  
}

function check_if_nodes_ready(){
    while [ $(oc get nodes | grep -E '\sReady\s' | wc -l) != 5 ]; do
    echo 'waiting for nodes to restart with status Ready'
    sleep 5
    done
}


# Run the below command in case of any clean resources are required in a cluster
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
echo "oc patch to operatorhub is completed"

kubectl apply -f - << EOD
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: mirror-registry
spec:
  repositoryDigestMirrors:
    - mirrors:
        - $OUTPUT_IMAGE
      source: registry.redhat.io
    - mirrors:
        - $OUTPUT_IMAGE
      source: registry.stage.redhat.io
    - mirrors:
        - $OUTPUT_IMAGE
      source: registry-proxy.engineering.redhat.com
    - mirrors:  
        - $OUTPUT_IMAGE
      source: quay.io/redhat-developer
EOD

check_if_nodes_ready

oc registry login --registry $OUTPUT_IMAGE --auth-basic=$USER_NAME:$PASSWORD --insecure=true
echo "oc logged into registry"

# mirroring the index image
manifests_result="$(oc image mirror $CATALOG_IMAGE $MIRROR_IMAGE_LOCATION --insecure)"

CATALOG_IMAGE_SHA=$(echo $manifests_result | awk '{print $1}')

oc adm catalog mirror $CATALOG_IMAGE@$CATALOG_IMAGE_SHA $OUTPUT_IMAGE --filter-by-os="linux/amd64" --insecure --manifests-only

grep $PRODUCT_NAME $CATALOG_IMAGE_NAME-manifests/mapping.txt > $CATALOG_IMAGE_NAME-manifests/$PRODUCT_NAME.txt

sed -i -e 's/\(.*\)\(:.*$\)/\1/' $CATALOG_IMAGE_NAME-manifests/$PRODUCT_NAME.txt

while read mapping;
    do
      for images in $mapping
      do
          FROM_IMAGE=$(cut -d'=' -f1 <<< $images)
          TO_IMAGE=$(cut -d'=' -f2 <<< $images)
          mirror_images $FROM_IMAGE $TO_IMAGE         
      done
    done < $CATALOG_IMAGE_NAME-manifests/$PRODUCT_NAME.txt


kubectl apply -f - << EOD
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOG_SOURCE_NAME
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: $MIRROR_IMAGE_LOCATION
  displayName: $CATALOG_SOURCE_NAME
  updateStrategy:
    registryPoll:
      interval: 30m
EOD
export CATALOG_SOURCE_NAME=$CATALOG_SOURCE_NAME