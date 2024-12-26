import axios from 'axios';
import { argv } from 'node:process';
import { argsParser, authenticate, getGroups, getRoles } from './shared.mjs';
import { v4 as uuidv4 } from 'uuid';
import subgroup from './subgroup.js';


let KEYCLOAK_BASE_URL;
let ADMIN_ACCESS_TOKEN;
let REALM_NAME;

let generateUUID = () => {
    return uuidv4();
};

async function createParentGroup({ tenantName }) {
    // "path": "/Tenant:<Tenant name>:<TenantUUID>/<RealmRole>",
    try {
        const tenantUuid = generateUUID();
        const baseTenantName = `Tenant:${tenantName}:${tenantUuid}`;
    
        let data = JSON.stringify({
            "name": baseTenantName,
            "path": `/${baseTenantName}`,
            "realmRoles": [],
            "subGroups": [],
            "access": {
                "view": true,
                "manage": true,
                "manageMembership": true
            }
        });
    
        await axios.request({
            method: 'post',
            maxBodyLength: Infinity,
            url: `${KEYCLOAK_BASE_URL}/admin/realms/${REALM_NAME}/groups`,
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${ADMIN_ACCESS_TOKEN}`
            },
            data: data
        });
    
        return baseTenantName;
    } catch (error) {
        console.error('[ERROR] err when creating parent group', error);
        throw error;
    }
}

async function createGroupRoleMapping(groupId, roleInfo) {
try {
        let data = JSON.stringify(
            [
                roleInfo
            ]
        );
    
        return await axios.request({
            method: 'post',
            maxBodyLength: Infinity,
            url: `${KEYCLOAK_BASE_URL}/admin/realms/${REALM_NAME}/groups/${groupId}/role-mappings/realm`,
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${ADMIN_ACCESS_TOKEN}`
            },
            data: data
        });
} catch (error) {
    console.error('[ERROR] err when creating group role mapping', error);
    throw error;
}
}

async function createSubGroup(subGroupToCreate, parentGroupId) {
   try {
     let data = JSON.stringify(
         subGroupToCreate
     );
     return await axios.request({
         method: 'post',
         maxBodyLength: Infinity,
         url: `${KEYCLOAK_BASE_URL}/admin/realms/${REALM_NAME}/groups/${parentGroupId}/children`,
         headers: {
             'Content-Type': 'application/json',
             'Authorization': `Bearer ${ADMIN_ACCESS_TOKEN}`
         },
         data: data
     });
   } catch (error) {
       console.error('[ERROR] err when creating sub group', error);
       throw error;
   }
}

async function createUser(baseTenantName, { tenantAdminName, tenantAdminPassword, tenantAdminEmail }) {
 try {
       const firstName = tenantAdminName.split(' ')[0];
       const lastName = tenantAdminName.split(' ')[1];
   
       let data = JSON.stringify({
           "firstName": firstName,
           "lastName": lastName,
           "email": tenantAdminEmail,
           "enabled": true,
           "groups": [`/${baseTenantName}/tenant_admins`],
           "credentials": [
               {
                   "type": "password",
                   "temporary": false,
                   "value": tenantAdminPassword
               }
           ],
           "realmRoles": [
               "tenant_admin",
           ]
       });
   
       let config = {
           method: 'post',
           maxBodyLength: Infinity,
           url: `${KEYCLOAK_BASE_URL}/admin/realms/${REALM_NAME}/users`,
           headers: {
               'Content-Type': 'application/json',
               'Authorization': `Bearer ${ADMIN_ACCESS_TOKEN}`
           },
           data: data
       };
   
       await axios.request(config);
   
 } catch (error) {
     console.error('[ERROR] err when creating user', error);
     throw error;
 }
}

async function initialise(params) {
    const { keycloakBaseUrl, accessToken, realm } = await authenticate(params);
    KEYCLOAK_BASE_URL = keycloakBaseUrl;
    ADMIN_ACCESS_TOKEN = accessToken;
    REALM_NAME = realm;
    return;
}

function parseArgs() {
    const args = argsParser(argv.slice(2),
        ['realm', 'client', 'secret', 'url', 'tenant_name', 'new_tenant_admin_name', 'tenant_admin_email', 'tenant_admin_password']);

    return {
        realm: args.realm,
        client: args.client,
        secret: args.secret,
        url: args.url,
        tenantName: args.tenant_name,
        tenantAdminName: args.new_tenant_admin_name,
        tenantAdminEmail: args.tenant_admin_email,
        tenantAdminPassword: args.tenant_admin_password
    };
}

async function start() {
    try {
        const onboardingInfo = parseArgs();
        await initialise(onboardingInfo);

        console.info('[INFO] parsed options', onboardingInfo);

        // create parent group
        const baseTenantName = await createParentGroup(onboardingInfo);
        console.info('[INFO] base tenant name', baseTenantName);

        // get newly created parent group id
        const groups = await getGroups({ keycloakBaseUrl: KEYCLOAK_BASE_URL, realm: REALM_NAME, accessToken: ADMIN_ACCESS_TOKEN });

        const { id: parentGroupId } = groups.find(g => g.name === baseTenantName);
        console.info('[INFO] new created parent group id', parentGroupId);

        // get all roles
        const realmRoles = await getRoles({ keycloakBaseUrl: KEYCLOAK_BASE_URL, realm: REALM_NAME, accessToken: ADMIN_ACCESS_TOKEN });

        // create subgroup(children group) and subsequently attach role to it
        const subgroupPromises = subgroup.map(async grp => {
            const realmRoleToAssign = grp.realmRoles;
            delete grp.realmRoles;

            const formattedPath = grp.path.replace(new RegExp(`{{baseTenantName}}`, 'g'), baseTenantName);
            grp.path = formattedPath;

            const { data: newSubGroupData } = await createSubGroup(grp, parentGroupId);
            console.info('[INFO] new created sub group path', newSubGroupData.path);

            const realmRoleData = realmRoles.find(r => r.name === realmRoleToAssign);

            console.info(`[INFO] create role mapping between group "${newSubGroupData.name}" and role "${realmRoleData.name}"`);
            await createGroupRoleMapping(newSubGroupData.id, realmRoleData);
        });

        await Promise.all(subgroupPromises);

        // create user
        console.info('[INFO] creating user');
        await createUser(baseTenantName, onboardingInfo);

        console.info(`--------DONE--------`);

    } catch (error) {
        throw error;
    }
}



start();