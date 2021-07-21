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


deploy_keycloak ()
{
    oc apply -k k8s/keycloak
    watch oc get pods -n keycloak
}



get_keycloak_auth ()
{
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
    KEYCLOAK_AUTH_TOKEN=$( curl -d "client_id=$CLIENT_ID" -d "username=${ADMIN_USERNAME}" -d "password=${ADMIN_PASSWORD}" -d "grant_type=$GRANT_TYPE" "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" | jq '.access_token' | sed s/\"//g)
}

create_keycloak_roles ()
{

    echo "Existing roles in ${AUTH_REALM}"
    curl -X GET ${KEYCLOAK_URL}/admin/realms/${AUTH_REALM}/roles \
      -H "Authorization: Bearer ${KEYCLOAK_AUTH_TOKEN=}" \


    echo "Creating our Keycloak Roles api-admins api-users admins"

    for new_role in api-admins api-users admins 
    do
        JSON="{\"name\": \"$new_role\"}"
        curl -X POST ${KEYCLOAK_URL}/admin/realms/${AUTH_REALM}/roles \
          -H "Authorization: Bearer ${KEYCLOAK_AUTH_TOKEN=}" \
          -H 'Content-Type: application/json' \
          -d "${JSON}"

    done

}

# We need to create the client config for our tradr app
create_keycloak_client ()
{

    # Debug code to pull existing clients back
    #curl -X GET ${KEYCLOAK_URL}/admin/realms/${AUTH_REALM}/clients \
      #-H "Authorization: Bearer ${KEYCLOAK_AUTH_TOKEN=}" \
    #| jq . -

    TRADR_URL=https://$(oc get route tradr -n daytrader --template='{{ .spec.host }}')

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
        curl -X POST ${KEYCLOAK_URL}/admin/realms/${AUTH_REALM}/clients \
          -H "Authorization: Bearer ${KEYCLOAK_AUTH_TOKEN=}" \
          -H 'Content-Type: application/json' \
          -d "${JSON}"


}


deploy_database ()
{
    
    kustomize build $PROJECT_HOME/k8s/db/prod | oc apply -f -

    # Need to implement a delay here while we wait for psql to load
    oc_wait_for  pod postgresql  app 

    # Importing DB Schema
    PSQL_POD=$(oc get pods -n daytrader -l "app=postgresql" -o jsonpath='{.items[0].metadata.name}')
    oc -n daytrader rsh ${PSQL_POD} psql -d tradedb < db/schema.sql
}

deploy_apps ()
{

    kustomize build $PROJECT_HOME/k8s/stock-quote/prod | oc apply -f -

    kustomize build $PROJECT_HOME/k8s/portfolio/prod | oc apply -f -

  
    KEYCLOAK_ROUTE=$(oc get route -n keycloak keycloak -o=jsonpath='{.spec.host}')
    oc set env -n daytrader deploy/quarkus-portfolio QUARKUS_OIDC_AUTH_SERVER_URL="https://$KEYCLOAK_ROUTE/auth/realms/stocktrader"
    echo "Wait 5 seconds for quarkus-portfolio to re-deploy"
    sleep 5s

    oc_wait_for pod quarkus-stock-quote app 
    oc_wait_for pod quarkus-portfolio   app 

    kustomize build $PROJECT_HOME/k8s/trade-orders-service/prod | oc apply -f -

    oc_wait_for pod trade-orders-service  app 

}



check_oc_login
deploy_keycloak
get_keycloak_auth 
create_keycloak_roles
create_keycloak_client

deploy_database
deploy_apps

