#!/bin/bash -xe

#MIRROR_REGISTRY

CATALOG_IMAGE_REGISTRY=${CATALOG_IMAGE_REGISTRY:-quay.io}
CATALOG_IMAGE_ORG=${CATALOG_IMAGE_ORG:-$QUAY_USERNAME}
CATALOG_IMAGE_NAME=${CATALOG_IMAGE_NAME:-servicebinding-operator}
CATALOG_IMAGE_TAG=${CATALOG_IMAGE_TAG:-index}
PRODUCT_NAME=${PRODUCT_NAME:-service-binding}
CATALOG_SOURCE_NAME='sb-operator-test'

CATALOG_INDEX_IMAGE=$CATALOG_IMAGE_REGISTRY/$CATALOG_IMAGE_ORG/$CATALOG_IMAGE_NAME:$CATALOG_IMAGE_TAG
MIRROR_IMAGE=$MIRROR_REGISTRY/$CATALOG_IMAGE_ORG/$CATALOG_IMAGE_NAME:$CATALOG_IMAGE_TAG

REGISTRY_USER="${REGISTRY_USER:-dummy}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-dummy}"

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
        - $MIRROR_REGISTRY/$CATALOG_IMAGE_ORG/$CATALOG_IMAGE_NAME
      source: $CATALOG_IMAGE_REGISTRY/$CATALOG_IMAGE_ORG/$CATALOG_IMAGE_NAME
EOD

sleep 10
check_if_nodes_ready

oc registry login --registry $MIRROR_REGISTRY --auth-basic=$REGISTRY_USER:$REGISTRY_USER --insecure=true
echo "oc logged into registry"

# mirroring the index image
manifests_result="$(oc image mirror $CATALOG_INDEX_IMAGE $MIRROR_IMAGE --insecure)"

CATALOG_IMAGE_SHA=$(echo $manifests_result | awk '{print $1}')

oc adm catalog mirror $CATALOG_IMAGE_REGISTRY/$CATALOG_IMAGE_ORG/$CATALOG_IMAGE_NAME@$CATALOG_IMAGE_SHA $MIRROR_IMAGE --to-manifests=$CATALOG_IMAGE_NAME-manifests --filter-by-os="linux/amd64" --insecure --manifests-only

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

AUTHFILE=$(readlink -m .authfile)
podman login --authfile $AUTHFILE --username $REGISTRY_USER --password $REGISTRY_PASSWORD $MIRROR_REGISTRY --tls-verify=false

# Use index.sh from SBO repo to install SBO from a given catalog index image
curl -s https://raw.githubusercontent.com/redhat-developer/service-binding-operator/master/install.sh | OPERATOR_INDEX_IMAGE=$CATALOG_INDEX_IMAGE DOCKER_CFG=$AUTHFILE /bin/bash -s