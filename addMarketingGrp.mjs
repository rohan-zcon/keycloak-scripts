import axios from 'axios';
import { argv } from 'node:process';
import { argsParser, authenticate, getGroups } from './shared.mjs';



async function addMarktSubGrp(path, parentGroupId, { keycloakBaseUrl, accessToken, realm}) {
    // "path": "/Tenant:Arcadia-DeSoto County Habitat for Humanity:c4b81cef-5738-42b4-961a-bd9463c22f1a/marketing",
    console.log("adding marketing subgrp for path: ", path);

    let data = JSON.stringify({
        "name": "marketing",
        "path": path,
        "realmRoles": [],
        "subGroups": [],
        "access": {
            "view": true,
            "manage": true,
            "manageMembership": true
        }
    });

    const response = await axios.request({
        method: 'post',
        maxBodyLength: Infinity,
        url: `${keycloakBaseUrl}/admin/realms/${realm}/groups/${parentGroupId}/children`,
        headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${accessToken}`
        },
        data: data
    });

    return response.data;
}

async function mapRole(subGrpId) {

    console.log("mapping marketing role for subgrpId: ", subGrpId);
    try {

        let data = JSON.stringify([
            {
                "id": "f5a4f598-8967-4555-a1ba-4a9e7062ce1f", //TODO: check for prod env id
                "name": "marketing",
                "composite": false,
                "clientRole": false
            }
        ]);

        let config = {
            method: 'post',
            maxBodyLength: Infinity,
            url: `${keyclaokUrl}/admin/realms/rehab-tracker-uat/groups/${subGrpId}/role-mappings/realm`,
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${token}`
            },
            data: data
        };

        await axios.request(config);
    } catch (error) {
        console.error("Error when mapping role for subgrpId: ", subGrpId);
        throw Error(error);
    }

}

async function main() {
    try {
        const args = argsParser(argv.slice(2), ['realm', 'client', 'secret', 'url']);
        const authResponse = await authenticate(args);
        const allGrps = await getGroups(authResponse);
        console.info("all groups:", allGrps);

        allGrps.map(async grp => {
                // add new sub grp for each grp
                const newSubGrpResp = await addMarktSubGrp(`${grp.path}/marketing`, grp.id);
                //    map role to new sub grp
                await mapRole(newSubGrpResp.id);
        });

        console.info(`------------Added marketing subgroups for ${allGrps.length} groups------------`);
        console.info(`--------DONE--------`);

    } catch (error) {
        console.error(error);
    }
}



await main();