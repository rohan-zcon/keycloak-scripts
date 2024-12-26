# Keycloak Scripts

This can be futher extended for particular use cases in future. 
Currently written in JS with future possibility of writing as a bash script to remove language dependency. This runs as a module so extension for files should be `mjs`. This was developed and tested on `node v18`.

###### Maintainer
Name: Rohan Sawant
Email: rohan.sawant@zconsolutions.com


## Usage

#### General usage
```bash
node <filename.mjs> --realm='<realm_name>' --client='<client_id>' --secret='<client_secret>' --url='<keycloak_baseurl>'
```

- `shared.mjs` has all the common operations like `authentication` which can be imported for other scripts.


#### Tenant onboarding
```bash 
node tenantOnboarding.mjs --realm=<REALM_NAME> --client='rehab-tracker-resource-server' --secret=<CLIENT_SECRET> --url='http://localhost:8080/auth' --tenant_name=<TENANT_NAME> --new_tenant_admin_name=<TENANT_ADMIN_NAME> --tenant_admin_email=<TENANT_ADMIN_EMAIL> --tenant_admin_password=<TENANT_ADMIN_PASSWORD>
```


