import { argv } from 'node:process';
import { argsParser, authenticate, getGroups } from "./shared.mjs";
import axios from 'axios';

async function deleteGrp(token, id) {

    let config = {
        method: 'delete',
        maxBodyLength: Infinity,
        url: `https://uat-kc.rehab-tracker.com/auth/admin/realms/rehab-tracker-uat/groups/${id}`,
        headers: {
            'Authorization': `Bearer ${token}`
        }
    };

   const response = await axios.request(config)
      


}

async function main() {
    try {
        const args = argsParser(argv.slice(2), ['realm', 'client', 'secret', 'url']);
        const authResponse = await authenticate(args);

        console.log("main ~ authResponse:", authResponse);


        const allGrps = await getGroups(authResponse);

        // console.log("main ~ allGrps:", allGrps);


        await Promise.all(allGrps.map(async grp => {
            // delete
            // const { id } = grp.subGroups.length > 0 && grp.subGroups.find(sg => sg.name === 'marketing');
            // console.log(id);

            if (grp.subGroups.length > 0) {
                grp.subGroups.forEach(async sg => {
                    if (sg.name === 'marketing') { 
                        await deleteGrp(authResponse.accessToken, sg.id); 
                    }
                });
            }
        }));

        console.info(`------------deleted marketing subgroups for ${allGrps.length} groups------------`);
        console.info(`--------DONE--------`);

    } catch (error) {
        console.error(error);
    }
}

await main()