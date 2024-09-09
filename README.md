# Keycloak Scripts

This can be futher extended for particular use cases in future. This runs as a module so extension for files should be `mjs`. This was written and tested on `node v18`.

### Usage

```bash
node <filename.mjs> --realm='<realm_name>' --client='<client_id>' --secret='<client_secret>' --url='<keycloak_baseurl>'
```

- `shared.mjs` has all the common operations like `authentication` which can be imported for other scripts.