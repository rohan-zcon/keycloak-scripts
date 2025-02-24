const { Sequelize } = require('sequelize');



const sequelize = new Sequelize(process.env.UAT_DB, process.env.UAT_DBUSER, process.env.UAT_DBPASSWORD, {
  host: process.env.UAT_DBHOST,
  dialect: 'postgres',
  dialectOptions: {
    ssl: {
      require: true,
      rejectUnauthorized: false
    }
  }
});


sequelize.authenticate().then(() => {
    console.log('Connection has been established successfully.');
  }).catch(err => {
    console.error('Unable to connect to the database:', err);
  });

