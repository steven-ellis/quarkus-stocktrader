#!/bin/bash

#
# Deployment wrapper for the Quarkus Stocktrader application
#
# The Keycloak REST automation is based on guides from
#  - https://dev.to/rounakcodes/keycloak-rest-api-for-realm-role-5hgp
#  - https://suedbroecker.net/2021/07/16/upload-an-user-to-keycloak-using-curl/

AUTH_REALM=stocktrader
PROJECT_HOME=`pwd`
OCP_NAMESPACE=daytrader

# oc_wait_for 
#
# $1 = [pod|node]
# $2 = app-name
# $3 = [app|name|role] - defaults to app
# $4 = namespace - defailts to ${OCP_NAMESPACE}
#
# EG
#    oc_wait_for pod rook-ceph-mon
#
oc_wait_for ()
{
    TYPE=${3:-app}
    NAMESPACE=${4:-$OCP_NAMESPACE}

    echo "Waiting for the ${1}s tagged ${2} = ready"
    oc wait --for condition=ready ${1} -l ${TYPE}=${2} -n ${NAMESPACE} --timeout=400s
}


# check_oc_login
#
# Make sure we're logged into OCP and grab our API endpoint
#
check_oc_login ()
{
    #OC_TOKEN=`oc whoami -t`
    OCP_USER=`oc whoami | sed "s/://"`

    OCP_ENDPOINT=`oc whoami --show-server`

    if [ "${OCP_USER}" == "" ]; then
      echo "You aren't logged into OpenShift at ${OCP_ENDPOINT}"
      exit 1
    else

      echo "You are logged into OpenShift as $OCP_USER at ${OCP_ENDPOINT}"
    fi
}


# Selected files need to be pre-configured before deployment
#
pre_checks ()
{
    echo

}

deploy_keycloak ()
{
    echo "======= deploy_keycloak ========"

    oc apply -k k8s/keycloak

    echo "Wait 10 seconds for keycloak to finish deploying and then check status"
    sleep 10s
    oc_wait_for pod keycloak  app  keycloak
    echo ""
    echo "Wait 10 seconds for the realm to populate"
    sleep 10s
}

delete_keycloak ()
{
    echo "======= delete_keycloak ========"
    echo "NOTE we don't remove the operator or the namespace"
    echo "only the realm and deployment"

    oc delete -n keycloak -f k8s/keycloak/realm.yaml
    oc delete -n keycloak -f k8s/keycloak/deployment.yaml
}

get_keycloak_auth ()
{
    echo "======= get_keycloak_auth ========"

    export ADMIN_USERNAME=$(oc get secrets credential-stocktrader-keycloak -n keycloak -ojson | jq -r '.data.ADMIN_USERNAME'| base64 -d)
    export ADMIN_PASSWORD=$(oc get secrets credential-stocktrader-keycloak -n keycloak -ojson | jq -r '.data.ADMIN_PASSWORD' | base64 -d)

    KEYCLOAK_URL=https://$(oc get route keycloak -n keycloak --template='{{ .spec.host }}')/auth &&
    echo "" &&
    echo "Keycloak:                 $KEYCLOAK_URL" &&
    echo "Keycloak Admin Console:   $KEYCLOAK_URL/admin" &&
    echo "Keycloak Account Console: $KEYCLOAK_URL/realms/myrealm/account" &&
    echo "" &&
    echo "Credentials ${ADMIN_USERNAME} : ${ADMIN_PASSWORD}" &&
    echo ""
    echo "Getting an auth token from keycloak"

    CLIENT_ID=admin-cli
    GRANT_TYPE=password
    KEYCLOAK_AUTH_TOKEN=$( curl -s -d "client_id=$CLIENT_ID" -d "username=${ADMIN_USERNAME}" -d "password=${ADMIN_PASSWORD}" -d "grant_type=$GRANT_TYPE" "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" | jq '.access_token' | sed s/\"//g)
}

create_keycloak_roles ()
{

    echo "======= create_keycloak_roles ========"
    echo "Existing roles in ${AUTH_REALM}"
    curl -s -X GET ${KEYCLOAK_URL}/admin/realms/${AUTH_REALM}/roles \
      -H "Authorization: Bearer ${KEYCLOAK_AUTH_TOKEN}" \


    echo ""
    echo "Creating our Keycloak Roles api-admins api-users admins"

    for new_role in api-admins api-users admins 
    do
        JSON="{\"name\": \"$new_role\"}"
        curl -s -X POST ${KEYCLOAK_URL}/admin/realms/${AUTH_REALM}/roles \
          -H "Authorization: Bearer ${KEYCLOAK_AUTH_TOKEN}" \
          -H 'Content-Type: application/json' \
          -d "${JSON}"

    done
    echo ""

}

create_keycloak_user ()
{
    echo "======= create_keycloak_user ========"

    echo "Existing users in ${AUTH_REALM}"
    curl -s -X GET ${KEYCLOAK_URL}/admin/realms/${AUTH_REALM}/users \
      -H "Authorization: Bearer ${KEYCLOAK_AUTH_TOKEN}" \
    | jq . -

JSON='
{
   "username": "user1",
   "enabled": true,
   "emailVerified": false,
   "firstName": "dummy",
   "lastName": "user",
   "credentials": [
       {
           "type": "password",
           "value": "password*",
           "temporary": false
       }
   ]
}'

   echo JSON  ${JSON}

    echo "Creating our Keycloak user user1"

        #JSON="{\"name\": \"$new_role\"}"
        curl -s -X POST ${KEYCLOAK_URL}/admin/realms/${AUTH_REALM}/users \
          -H "Authorization: Bearer ${KEYCLOAK_AUTH_TOKEN}" \
          -H 'Content-Type: application/json' \
          -d "${JSON}"

#          -d '{"firstName":"Dummy","lastName":"User", "email":"test@test.com", "enabled":"true", "username":"user1", "realmRoles":["api-admins"]}'


    USER_ID=$(curl -s -X GET ${KEYCLOAK_URL}/admin/realms/${AUTH_REALM}/users \
              -H "Authorization: Bearer ${KEYCLOAK_AUTH_TOKEN}" \
            | jq  -r '.[] | select(.username=="user1") | .id')

    echo "User user1 has ID ${USER_ID}"

    curl -s -X GET ${KEYCLOAK_URL}/admin/realms/${AUTH_REALM}/roles \
              -H "Authorization: Bearer ${KEYCLOAK_AUTH_TOKEN}" \
    | jq . -

    ROLE_ID=$(curl -s -X GET ${KEYCLOAK_URL}/admin/realms/${AUTH_REALM}/roles \
              -H "Authorization: Bearer ${KEYCLOAK_AUTH_TOKEN}" \
            | jq  -r '.[] | select(.name=="api-admins") | .id')

    echo "Role api-admins has ID ${ROLE_ID}"

        JSON="
[
  {
    \"id\": \"${ROLE_ID}\",
    \"name\": \"api-admins\"
  }
]

"

    echo "Add role api-admins to user user1"
    echo "Using JSON ${JSON}"

        curl -s -X POST ${KEYCLOAK_URL}/admin/realms/${AUTH_REALM}/users/${USER_ID}/role-mappings/realm \
          -H "Authorization: Bearer ${KEYCLOAK_AUTH_TOKEN}" \
          -H 'Content-Type: application/json' \
          -d "${JSON}"

}


# We need to create the client config for our tradr app
create_keycloak_client ()
{
    echo "======= create_keycloak_client ========"

    # Debug code to pull existing clients back
    #curl -X GET ${KEYCLOAK_URL}/admin/realms/${AUTH_REALM}/clients \
      #-H "Authorization: Bearer ${KEYCLOAK_AUTH_TOKEN}" \
    #| jq . -

    TRADR_URL=https://$(oc get route tradr -n daytrader --template='{{ .spec.host }}')

    echo "Creating our Keycloak client config for the tradr app"
    echo "Creating our Keycloak client config for the tradr app"

        JSON="
{
    \"clientId\": \"tradr\",
    \"rootUrl\": \"${TRADR_URL}\",
    \"redirectUris\":
    [
        \"*\"
    ]
}
"
	#echo $JSON
	#echo $JSON | jq . -
        curl -s -X POST ${KEYCLOAK_URL}/admin/realms/${AUTH_REALM}/clients \
          -H "Authorization: Bearer ${KEYCLOAK_AUTH_TOKEN}" \
          -H 'Content-Type: application/json' \
          -d "${JSON}"


}

delete_kafka ()
{
    echo "======= delete_kafka ========"

    oc delete -k k8s/kafka/prod

}

deploy_kafka ()
{
    echo "======= deploy_kafka ========"

    oc apply -k k8s/kafka/prod
    sleep 40s

    oc get pods --show-labels
    oc_wait_for pod daytrader app.kubernetes.io/instance
    sleep 60s
    oc_wait_for pod daytrader-entity-operator strimzi.io/name
    sleep 20s
}


# We need to update the entries in the file
#  $PROJECT_HOME/k8s/kafka-mirrormaker/base/daytrader-mirrormaker-example.yaml
# and save it as
#  $PROJECT_HOME/k8s/kafka-mirrormaker/base/daytrader-mirrormaker.yaml
#
kafka_mirror_maker ()
{

    echo "======= kafka_mirror_maker ========"
    # If we're not on AWS this should be non-zero
    KAFKA_ROUTE=$(oc get svc -n daytrader daytrader-kafka-external-bootstrap \
                  -n daytrader \
                  -ojsonpath='{.status.loadBalancer.ingress[0].ip}')

    if [ "${KAFKA_ROUTE}" = "" ]; then
        KAFKA_ROUTE=$(oc get svc -n daytrader daytrader-kafka-external-bootstrap \
                      -n daytrader \
                      -ojsonpath='{.status.loadBalancer.ingress[0].hostname}')
         echo "Running on AWS"
    else
         echo "Not on AWS"
    fi
    echo "Kafka Route = ${KAFKA_ROUTE}"
 
    cat $PROJECT_HOME/k8s/kafka-mirrormaker/base/daytrader-mirrormaker-example.yaml |\
    sed "s/<legacy bootstrap address>/20.197.67.109/" |\
    sed "s/<modern bootstrap address>/${KAFKA_ROUTE}/" |\
    cat > $PROJECT_HOME/k8s/kafka-mirrormaker/base/daytrader-mirrormaker.yaml

    # Deploy mirror maker
    kustomize build $PROJECT_HOME/k8s/kafka-mirrormaker/prod | oc apply -f -
}
    
deploy_database ()
{
    
    echo "======= deploy_database ========"
    kustomize build $PROJECT_HOME/k8s/db/prod | oc apply -f -

    # Need to implement a delay here while we wait for psql to load
    oc_wait_for  pod postgresql  app 

    # Importing DB Schema
    PSQL_POD=$(oc get pods -n daytrader -l "app=postgresql" -o jsonpath='{.items[0].metadata.name}')
    oc -n daytrader rsh ${PSQL_POD} psql -d tradedb < db/schema.sql
}


# This will also delete the namespace and is usually sufficient should
# we need to clean up the environment for a fresh install
#
delete_database ()
{

    echo "======= delete_database ========"
    kustomize build $PROJECT_HOME/k8s/db/prod | oc delete -f -

}

deploy_apps ()
{

    echo "======= deploy_apps ========"
    kustomize build $PROJECT_HOME/k8s/stock-quote/prod | oc apply -f -

    kustomize build $PROJECT_HOME/k8s/portfolio/prod | oc apply -f -

  
    KEYCLOAK_ROUTE=$(oc get route -n keycloak keycloak -o=jsonpath='{.spec.host}') 
    oc set env -n daytrader deploy/quarkus-portfolio \
        QUARKUS_OIDC_AUTH_SERVER_URL="https://$KEYCLOAK_ROUTE/auth/realms/stocktrader"
    echo "Wait 5 seconds for quarkus-portfolio to re-deploy"
    sleep 5s

    oc_wait_for pod quarkus-stock-quote app 
    oc_wait_for pod quarkus-portfolio   app 

    kustomize build $PROJECT_HOME/k8s/trade-orders-service/prod | oc apply -f -

    oc_wait_for pod trade-orders-service  app 
    
    sleep 2s
    #oc_wait_for route trade-orders  app 
 
    echo "We currently assume the Tradr app has been uploaded to Quay"
    kustomize build $PROJECT_HOME/k8s/tradr/prod | oc apply -f -
    oc_wait_for pod tradr  app 


}


check_status ()
{
    echo "======= check_status ========"
    export TRADER_ROUTE="https://$(oc get route -n ${OCP_NAMESPACE} tradr -o jsonpath='{.spec.host}')"

    echo ""
    echo "You should now be able to access the modern application on"
    echo $TRADER_ROUTE


    export KAFKA_ROUTE="https://$(oc get route -n ${OCP_NAMESPACE} trader-orders -o jsonpath='{.spec.host}')"

    echo ""
    echo "And the Kafka Data Replication App at "
    echo $TRADER_ROUTE


}

check_oc_login

case "$1" in
  deploy)
        deploy_keycloak
        get_keycloak_auth 
        create_keycloak_roles

        deploy_kafka

        deploy_database

        # We use this order to give time for the
        # LoadBalancers to come up
        kafka_mirror_maker 


        deploy_apps

        get_keycloak_auth 
        create_keycloak_client
        create_keycloak_user 
        check_status

        ;;
  status)
        check_status
        get_keycloak_auth 
        ;;
  delete|cleanup|remove)
        delete_database
        delete_keycloak 
        ;;
  *)
        echo "Usage: $N {deploy|status|remove|cleanup}" >&2
        exit 1
        ;;
esac

