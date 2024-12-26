module.exports= [
    {
        "name": 'tenant_admins',
        "path": '/{{baseTenantName}}/tenant_admins',
        "subGroups": [],
        "realmRoles": "tenant_admin",
        "access": {
            "view": true,
            "manage": true,
            "manageMembership": true
        }
    },
    {
        "name": 'marketing',
        "path": '/{{baseTenantName}}/marketing',
        "subGroups": [],
        "realmRoles": "marketing",
        "access": {
            "view": true,
            "manage": true,
            "manageMembership": true
        }
    },
    {
        "name": 'project_admins',
        "path": '/{{baseTenantName}}/project_admins',
        "subGroups": [],
        "realmRoles": "project_admin",
        "access": {
            "view": true,
            "manage": true,
            "manageMembership": true
        }
    },
    {
        "name": 'compliance_audiators',
        "path": '/{{baseTenantName}}/compliance_audiators',
        "subGroups": [],
        "realmRoles": "compliance_audiator",
        "access": {
            "view": true,
            "manage": true,
            "manageMembership": true
        }
    },
    {
        "name": 'account_managers',
        "path": '/{{baseTenantName}}/account_managers',
        "subGroups": [],
        "realmRoles": "account_manager",
        "access": {
            "view": true,
            "manage": true,
            "manageMembership": true
        }
    },
    {
        "name": 'project_managers',
        "path": '/{{baseTenantName}}/project_managers',
        "subGroups": [],
        "realmRoles": "project_manager",
        "access": {
            "view": true,
            "manage": true,
            "manageMembership": true
        }
    }
];