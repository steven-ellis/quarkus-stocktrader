#!/bin/bash

#
# Deployment wrapper for the Quarkus Stocktrader application
#
# The Keycloak REST automation is based on guides from
#  - https://dev.to/rounakcodes/keycloak-rest-api-for-realm-role-5hgp
#  - https://suedbroecker.net/2021/07/16/upload-an-user-to-keycloak-using-curl/

AUTH_REALM=stocktrader

deploy_keycloak ()
{
    oc apply -k k8s/keycloak
    watch oc get pods -n keycloak
}



get_keyclock_auth ()
{
    export ADMIN_USERNAME=$(oc get secrets credential-stocktrader-keycloak -n keycloak -ojson | jq -r '.data.ADMIN_USERNAME'| base64 -d)
    export ADMIN_PASSWORD=$(oc get secrets credential-stocktrader-keycloak -n keycloak -ojson | jq -r '.data.ADMIN_PASSWORD' | base64 -d)

    KEYCLOAK_URL=https://$(oc get route keycloak --template='{{ .spec.host }}')/auth &&
    echo "" &&
    echo "Keycloak:                 $KEYCLOAK_URL" &&
    echo "Keycloak Admin Console:   $KEYCLOAK_URL/admin" &&
    echo "Keycloak Account Console: $KEYCLOAK_URL/realms/myrealm/account" &&
    echo "" &&
    echo "Credentials ${ADMIN_USERNAME} : ${ADMIN_PASSWORD}" &&
    echo ""
    echo "Getting an auth token from keyclock"

    CLIENT_ID=admin-cli
    GRANT_TYPE=password
    KEYCLOAK_AUTH_TOKEN=$( curl -d "client_id=$CLIENT_ID" -d "username=${ADMIN_USERNAME}" -d "password=${ADMIN_PASSWORD}" -d "grant_type=$GRANT_TYPE" "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" | jq '.access_token' | sed s/\"//g)
}

create_keyclock_roles ()
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

# deploy_keycloak
get_keyclock_auth 
create_keyclock_roles


