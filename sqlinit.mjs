import 'dotenv/config'
import { argv } from 'node:process';
import { argsParser } from './shared.mjs';
import Sequelize from 'sequelize';
const uatConfig = {
    host: process.env.UAT_DBHOST,
    user: process.env.UAT_DBUSER,
    password: process.env.UAT_DBPASSWORD,
    database: process.env.UAT_DB,
    driver: 'postgres',
    dialect: 'postgres'
};

const prodConfig = {
    host: process.env.PROD_DBHOST,
    user: process.env.PROD_DBUSER,
    password: process.env.PROD_DBPASSWORD, 
    database: process.env.PROD_DB,
    driver: 'postgres',
    dialect: 'postgres'
};


const startConnection = async (env, ssl) => {
    let connectionInfo;
    let sequelize;

    console.info("[INFO] Connecting to relational database...");

    connectionInfo = env === 'uat' ? uatConfig : prodConfig;

    if (ssl === 'true') connectionInfo = { ...connectionInfo, dialectOptions: { ssl: 'Amazon RDS' } };

    console.dir({ connectionInfo });
    sequelize = new Sequelize(
        connectionInfo.database,
        connectionInfo.user,
        connectionInfo.password,
        {
            host: connectionInfo.host,
            dialect: connectionInfo.driver,
            pool: {
                max: connectionInfo.connectionLimit,
                min: 0,
            },
        }
    );

    await sequelize.authenticate();

    console.info("[INFO] Database connection ready");
    return;
};

async function start() {
    try {
        const args = argsParser(argv.slice(2), ['env', 'ssl']);
        console.log("start ~ args:", args);

        await startConnection(args.env, args.ssl);


    } catch (error) {
        console.error('[ERROR] Unable to connect to the database:', error);
    }
}

start();