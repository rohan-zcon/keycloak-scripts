import axios from 'axios';
import qs from 'querystring';
import { argv } from 'node:process';
import { argsParser, authenticate } from './shared.mjs';

// const {argv} = require('node:process');
// const {authenticate} = require('./shared.mjs');


let token = null;
let refresh = null;
let keyclaokUrl;


const setTokenRefreshTimeout = (authResponse) => {
    if (refresh) clearTimeout(refresh);

    console.info("Setting token refresh timeout...");

    refresh = setTimeout(() => {
        refreshToken(authResponse.data.refresh_token);
    }, parseInt(authResponse.data.expires_in) * 1000 - 10);

    console.info("Token refresh set");
};

const buildHeaders = () => {
    const accessToken = token;
    const auth = "Bearer " + accessToken;
    return {
        "content-type": "application/json",
        Authorization: auth
    };

};


// node index.mjs -realm 'rehab-tracker-uat' -client 'rehab-tracker-resource-server' -secret '849a91a4-e2d1-447e-9277-59d14dc7b531'

// async function authenticate({ url, client, secret, realm }) {
//     console.info("Authenticating with identity provider...");
//     const oauthClient = axios.create({ baseURL: `${url}/realms/${realm}` });
//     oauthClient.defaults.headers.post["Content-Type"] =
//         "application/x-www-form-urlencoded";
//     try {
//         let data = qs.stringify({
//             'grant_type': 'client_credentials',
//             'client_id': client,
//             'client_secret': secret
//         });

//         let config = {
//             method: 'post',
//             maxBodyLength: Infinity,
//             url: 'https://uat-kc.rehab-tracker.com/auth/realms/rehab-tracker-uat/protocol/openid-connect/token',
//             headers: {
//                 'Content-Type': 'application/x-www-form-urlencoded'
//             },
//             data: data
//         };
//         let authResponse = await axios.request(config);
//         console.info("Authenticated with identity provider");

//         token = authResponse.data.access_token;

//         keyclaokUrl = url;
//         return authResponse;
//     } catch (err) {
//         console.log(err);
//         throw err;
//     }
// }

async function getGroups() {
    let config = {
        method: 'get',
        maxBodyLength: Infinity,
        url: `${keyclaokUrl}/admin/realms/rehab-tracker-uat/groups`,
        headers: {
            'Authorization': `Bearer ${token}`
        }
    };
    const { data } = await axios.request(config);

    return data;
}

async function addMarktSubGrp(path, parentGroupId) {
    let data = JSON.stringify({
        // "path": "/Tenant:Arcadia-DeSoto County Habitat for Humanity:c4b81cef-5738-42b4-961a-bd9463c22f1a/marketing",
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

    let config = {
        method: 'post',
        maxBodyLength: Infinity,
        url: `${keyclaokUrl}/admin/realms/rehab-tracker-uat/groups/${parentGroupId}/children`,
        headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${token}`
        },
        data: data
    };

    const response = await axios.request(config);

    console.log("addMarktSubGrp ~ response:", response.data);
    return response.data;

}

async function mapRole(subGrpId) {

    console.log("mapRole ~ subGrpId:", subGrpId);

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

    const response = await axios.request(config);

    console.log("mapRole ~ response:", response);
}

// function parseArgs(args) {
//     const ARGS_OPTIONS = ['realm', 'client', 'secret', 'url'];
//     const parsedArgs = {};

//     args.forEach(arg => {
//         const [k, v] = arg.split('=');
//         const key = k.slice(k.indexOf('--') + 2);
//         if (!ARGS_OPTIONS.includes(key)) throw new Error('invalid args');
//         parsedArgs[key] = v;
//     });
//     return parsedArgs;
// }

async function main() {
    const PLAY = ['068df3e3-e18a-4d0b-a8fb-caa5c050654c', '01bab3a0-2d1d-4bd9-9df7-2c78a062a144', '1bb8c537-8349-46e1-879f-0c2b419222fc'];
    try {
        // const args = parseArgs(argv.slice(2));
        const args = argsParser(argv.slice(2), ['realm', 'client', 'secret', 'url']);


        const response = await authenticate(args) 

        console.log("main ~ response:", response);

        

        // if (!token) await authenticate(args);
        // const allGrps = await getGroups();


        // console.log("main ~ allGrps:", allGrps);


        // const todos = allGrps.filter(g => PLAY.includes(g.id));

        // console.log("main ~ todos:", todos);

        // todos.map(async grp => {
        //         // add new sub grp for each grp
        //         const newSubGrpResp = await addMarktSubGrp(`${grp.path}/marketing`, grp.id);
        //         //    map role to new sub grp
        //         await mapRole(newSubGrpResp.id);

        // });

        // console.info(`----DONE----`);

        // const allGrpsAfter = await getGroups();

        // const todosAfter = allGrpsAfter.filter(g => PLAY.includes(g.id));

        // console.log("main ~ todosAfter:", todosAfter);
    } catch (error) {
        console.error(error);
    }
}

await main();