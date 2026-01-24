# LDAP Configuration Guide for Apache NiFi Helm Chart

This guide explains how to configure LDAP authentication for Apache NiFi using this Helm chart, based on the working Docker configuration.

## Table of Contents

1. [Overview](#overview)
2. [Critical Configuration Points](#critical-configuration-points)
3. [Configuration Steps](#configuration-steps)
4. [Example Configurations](#example-configurations)
5. [Troubleshooting](#troubleshooting)

## Overview

LDAP authentication in NiFi requires careful configuration of two main components:
- **login-identity-providers.xml**: Handles user authentication
- **authorizers.xml**: Handles user authorization and permissions

This Helm chart automates the configuration of both components based on the values you provide.

## Critical Configuration Points

### 1. Identity Strategy (CRITICAL)

The `identityStrategy` setting determines how user identities are represented:

- **USE_USERNAME** (Recommended): Uses just the username (e.g., `nifi-admin`)
- **USE_DN**: Uses the full Distinguished Name (e.g., `uid=nifi-admin,ou=users,dc=nifi,dc=org`)

**Why USE_USERNAME?**
When `identityStrategy: USE_USERNAME` is set:
- User logs in with username: `nifi-admin`
- Identity stored in NiFi: `nifi-admin`
- `initialAdminIdentity` should be: `nifi-admin`

When `identityStrategy: USE_DN` (NOT RECOMMENDED):
- User logs in with username: `nifi-admin`
- Identity stored in NiFi: `uid=nifi-admin,ou=users,dc=nifi,dc=org`
- `initialAdminIdentity` must be: `uid=nifi-admin,ou=users,dc=nifi,dc=org`

**This is the #1 cause of "Insufficient Permissions" errors.**

### 2. Initial Admin Identity

Must match **exactly** what the identity will be after authentication:
- If `identityStrategy: USE_USERNAME`, use the uid: `nifi-admin`
- If `identityStrategy: USE_DN`, use the full DN: `uid=nifi-admin,ou=users,dc=nifi,dc=org`

### 3. User Provider Order

The Helm chart uses a **composite user provider** that combines:
1. **file-user-group-provider**: For cluster node identities (certificates)
2. **ldap-user-group-provider**: For LDAP users and groups

**Important**: Each user must exist in only ONE provider to avoid conflicts.

### 4. Clean State on Startup

When LDAP is enabled, the Helm chart automatically removes existing `users.xml` and `authorizations.xml` files on startup to ensure a clean state. This prevents conflicts from previous authentication configurations.

## Configuration Steps

### Step 1: Enable LDAP in values.yaml

```yaml
global:
  nifi:
    nodeCount: 3  # LDAP supports multi-node clusters
  
  ldap:
    enabled: true
    url: "ldap://ldap-server:389"  # or ldaps://ldap-server:636 for TLS
    authenticationStrategy: SIMPLE  # or LDAPS for TLS
    identityStrategy: USE_USERNAME  # RECOMMENDED
    initialAdminIdentity: "nifi-admin"  # Username only, not DN
    
    manager:
      distinguishedName: "cn=admin,dc=nifi,dc=org"
      password: "admin"  # Or use passwordSecretRef for production
    
    userSearchBase: "ou=users,dc=nifi,dc=org"
    userSearchFilter: "uid={0}"
```

### Step 2: Configure LDAP Server

Ensure your LDAP server has:
- User entries with the `uid` attribute
- Proper organizational units (OUs) for users and groups
- Manager account with read permissions

Example LDAP structure:
```
dc=nifi,dc=org
├── ou=users
│   └── uid=nifi-admin (with password)
└── ou=groups
    └── cn=nifi-admins (with memberUid=nifi-admin)
```

### Step 3: Deploy the Helm Chart

```bash
helm install nifi . -f your-values.yaml
```

### Step 4: Access NiFi

Once deployed, access NiFi at the configured hostname:
- URL: `https://your-hostname/nifi`
- Username: `nifi-admin` (or whatever you configured)
- Password: The password set in LDAP

## Example Configurations

### Simple LDAP (Non-TLS)

See [examples/values-ldap-simple.yaml](../examples/values-ldap-simple.yaml) for a complete example.

Key configuration:
```yaml
global:
  ldap:
    enabled: true
    url: "ldap://ldap-server:389"
    authenticationStrategy: SIMPLE
    identityStrategy: USE_USERNAME
    initialAdminIdentity: "nifi-admin"
    userSearchFilter: "uid={0}"
```

### LDAPS (TLS Encrypted)

```yaml
global:
  ldap:
    enabled: true
    url: "ldaps://ldap-server:636"
    authenticationStrategy: LDAPS
    tlsProtocol: TLSv1.2
    identityStrategy: USE_USERNAME
    initialAdminIdentity: "nifi-admin"
```

### Active Directory

For Active Directory, use:
```yaml
global:
  ldap:
    enabled: true
    url: "ldaps://dc.example.com:636"
    authenticationStrategy: LDAPS
    identityStrategy: USE_USERNAME
    initialAdminIdentity: "Administrator"
    
    manager:
      distinguishedName: "CN=Administrator,DC=example,DC=com"
      password: "password"
    
    userSearchBase: "DC=example,DC=com"
    userSearchFilter: "sAMAccountName={0}"
    
    # Active Directory groups
    groupSearchBase: "DC=example,DC=com"
    groupSearchFilter: "(member={0})"
    groupMembershipAttribute: "member"
```

## Troubleshooting

### Issue: "Insufficient Permissions"

**Symptoms**: User can log in but sees "Insufficient Permissions - Unable to view the user interface"

**Solutions**:
1. Verify `identityStrategy: USE_USERNAME` in values.yaml
2. Verify `initialAdminIdentity` matches the uid (e.g., `nifi-admin`, not the full DN)
3. Check pod logs for authentication details:
   ```bash
   kubectl logs nifi-0 | grep -i "ldap\|authentication\|authorization"
   ```
4. Restart pods to ensure clean state:
   ```bash
   kubectl rollout restart statefulset/nifi
   ```

### Issue: "Multiple UserGroupProviders are claiming to provide user"

**Symptoms**: Error in logs about duplicate user in multiple providers

**Solutions**:
- This should not happen with the Helm chart as it properly configures the composite provider
- If it does occur, it means the user exists in both LDAP and was manually added to users.xml
- Delete the StatefulSet and redeploy to get a clean state

### Issue: "No applicable policies could be found"

**Symptoms**: Error after successful login

**Solutions**:
1. Delete the persistent config volume to start fresh:
   ```bash
   kubectl delete pvc config-nifi-0
   kubectl delete pod nifi-0
   ```
2. Verify the initialAdminIdentity exactly matches what LDAP returns

### Issue: Cannot connect to LDAP server

**Symptoms**: Connection timeout or refused errors

**Solutions**:
1. Verify LDAP server is accessible from pods:
   ```bash
   kubectl exec -it nifi-0 -- nc -zv ldap-server 389
   ```
2. Check LDAP URL format:
   - Non-TLS: `ldap://hostname:389`
   - TLS: `ldaps://hostname:636`
3. Verify DNS resolution:
   ```bash
   kubectl exec -it nifi-0 -- nslookup ldap-server
   ```

### Issue: Authentication fails

**Symptoms**: "Bad credentials" or "Invalid username/password"

**Solutions**:
1. Verify manager DN and password are correct
2. Test LDAP search manually:
   ```bash
   kubectl exec -it nifi-0 -- ldapsearch -x -H ldap://ldap-server:389 \
     -D "cn=admin,dc=nifi,dc=org" -w "admin" \
     -b "ou=users,dc=nifi,dc=org" "(uid=nifi-admin)"
   ```
3. Check userSearchBase and userSearchFilter are correct

## How It Works

### Startup Process

When LDAP is enabled, the startup script ([configmap.yaml](../templates/configmap.yaml)) performs these steps:

1. **Clean State**: Removes existing `users.xml` and `authorizations.xml` from persistent storage
2. **Configure login-identity-providers.xml**:
   - Creates or updates the `ldap-provider` with your settings
   - Removes `single-user-provider`
   - Sets `Identity Strategy` to control how usernames are handled
3. **Configure authorizers.xml**:
   - Enables and configures `ldap-user-group-provider`
   - Enables `composite-configurable-user-group-provider`
   - Sets up `file-user-group-provider` for cluster nodes
   - Configures `managed-authorizer` with initial admin identity
4. **Start NiFi**: NiFi will create new `users.xml` and `authorizations.xml` based on the configuration

### User and Group Synchronization

- **Users**: Synchronized from LDAP on each login and periodically (every 5 minutes by default)
- **Groups**: Synchronized from LDAP if `groupSearchBase` is configured
- **Node Identities**: Stored in `file-user-group-provider` (certificate-based)
- **Admin User**: Granted full permissions via `initialAdminIdentity`

## Security Best Practices

1. **Use LDAPS**: Always use TLS encryption for production (`authenticationStrategy: LDAPS`)
2. **Use Secrets**: Store manager password in a Kubernetes secret:
   ```yaml
   manager:
     passwordSecretRef:
       name: ldap-credentials
       key: password
   ```
3. **Limit Manager Permissions**: The manager DN only needs read access to users and groups
4. **Use Strong Passwords**: Ensure LDAP user passwords meet security requirements
5. **Regular Backups**: Backup `users.xml` and `authorizations.xml` from persistent storage

## References

- [Apache NiFi Admin Guide - User Authentication](https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html#user_authentication)
- [Apache NiFi Admin Guide - LDAP](https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html#ldap_login_identity_provider)
- [Apache NiFi Admin Guide - Authorizers](https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html#authorizers-setup)
- [Docker Configuration Documentation](../DOCUMENTACION_NIFI_LDAP.md)
