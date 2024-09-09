import axios from 'axios';
import qs from 'querystring';


/**
 * Parse CLI args
 * 
 * @param {string[]} args Raw CLI args
 * @param {string[]} validArgsOpts Valid expected arguments
 * @returns {{key: string, value: string}} Object with parsed key value pairs
 */
export function argsParser(args , validArgsOpts) {
    const parsedArgs = {};
    args.forEach(arg => {
        const [k, v] = arg.split('=');
        const key = k.slice(k.indexOf('--') + 2);
        if (!validArgsOpts.includes(key)) throw new Error(`invalid arg: ${key}`);
        parsedArgs[key] = v;
    });
    return parsedArgs;
}


/**
 * Authenticate with keycloak instance
 * 
 * @param {Object} authParams 
 * @param {string} authParams.url Keycloak's base url
 * @param {string} authParams.client Keycloak's clientId
 * @param {string} authParams.secret Keycloak's clientSecret
 * @param {string} authParams.realm Keycloak's realm
 * @returns {{keycloakBaseUrl:string, accessToken:string, realm:string}} Return object of required auth configs
 * @throws Error
 */
export async function authenticate({ url, client, secret, realm }) {
    console.info("Authenticating with identity provider...");
    console.info({ url, realm });

    try {
        let data = qs.stringify({
            'grant_type': 'client_credentials',
            'client_id': client,
            'client_secret': secret
        });

        let config = {
            method: 'post',
            maxBodyLength: Infinity,
            url: `${url}/realms/${realm}/protocol/openid-connect/token`,
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded'
            },
            data: data
        };
        let authResponse = await axios.request(config);
        console.info("Authenticated with identity provider...");
        return { keycloakBaseUrl: url, accessToken: authResponse.data.access_token, realm  };
    } catch (err) {
        console.log(err);
        throw err;
    }
}


/**
 * Get all groups for keycloak instance
 * 
 * @param {{keycloakBaseUrl:string, accessToken:string, realm:string }} AuthConfigs configs returned after authentication
 * @returns {Object[]} All groups
 */
export async function getGroups({ keycloakBaseUrl, accessToken, realm }) {
    const { data } = await axios.request({
        method: 'get',
        maxBodyLength: Infinity,
        url: `${keycloakBaseUrl}/admin/realms/${realm}/groups`,
        headers: {
            'Authorization': `Bearer ${accessToken}`
        }
    });

    return data;
}
