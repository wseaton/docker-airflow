#!/usr/bin/env python
import json
import os
import string
import sys
import sysconfig
import urllib3
from enum import Enum

# This script should be called before starting the airflow webserver.
# It writes the webserver_config.py file in the Airflow's home directory
# to turn on the user authentication.

auth_type = os.getenv('AUTH_TYPE')
if auth_type != "openshift":
    sys.exit(0)

openshift_oauth_config_template = string.Template("""
from airflow.www_rbac.security import AirflowSecurityManager
from flask_appbuilder.security.manager import AUTH_OAUTH
AUTH_TYPE = AUTH_OAUTH
OAUTH_PROVIDERS = [
    {
        "name": "openshift",
        "icon": "fa-circle-o",
        "token_key": "access_token",
        "remote_app": {
            "consumer_key": "$client_id",
            "consumer_secret": "$client_secret",
            "request_token_params": {
                "scope": "user:info"
            },
            "base_url": "$server_url",
            "access_token_url": "$token_endpoint",
            "authorize_url": "$authorization_endpoint",
            "access_token_method": "POST",
        },
    }
]

AUTH_USER_REGISTRATION = True
$auth_user_registration_role

from base64 import b64decode

import ldap
from ldap.dn import str2dn, explode_dn

def get_email_from_identity(identity: str) -> str:
    
    provider, info = identity.split(':')

    if provider == "LDAP":
        info = b64decode(info).decode('utf-8')
        dn = explode_dn(info, flags=ldap.DN_FORMAT_LDAPV3)
        email = "{0}@{2}.{3}".format(*[x.split('=')[-1] for x in dn])
    else:
        return ""

    return email

from airflow.www_rbac.app import appbuilder

class OpenShiftSecurity(AirflowSecurityManager):
    def oauth_user_info(self, provider, response=None):
        if provider == "openshift":
            me = self.appbuilder.sm.oauth_remotes[provider].get(
                "apis/user.openshift.io/v1/users/~"
            )
            data = me.data
            print("User info from OCP: {0}".format(data))
            return {
                "username": "openshift_" + data.get("metadata").get("name"),
                "email" : get_email_from_identity(data.get("identities")[0]) 
            }
        else:
            return {}

SECURITY_MANAGER_CLASS = OpenShiftSecurity 
""")

def generate_openshift_oauth_config():
    # Well-known discovery URL
    server_url = 'https://openshift.default.svc.cluster.local'

    config_values = dict()
    config_values['server_url'] = server_url

    # Discover the authorization endpoint and the token endpoint
    auth_info_url = "%s/.well-known/oauth-authorization-server" % server_url
    http = urllib3.PoolManager()
    response = http.request('GET', auth_info_url)
    data = json.loads(response.data.decode('UTF-8'))
    config_values['authorization_endpoint'] = data['authorization_endpoint']
    config_values['token_endpoint'] = data['token_endpoint']

    # Grab the OpenShift authorization token
    token_path = '/var/run/secrets/kubernetes.io/serviceaccount/token'
    with open(token_path) as fp:
        token = fp.read().strip()

    # Discover the client_id and set the client_secret
    user_info_url = "%s/apis/user.openshift.io/v1/users/~" % server_url
    response = http.request('GET', user_info_url, headers = { "Authorization": ("Bearer %s" % token) })
    data = json.loads(response.data.decode('UTF-8'))
    config_values['client_id'] = data['metadata']['name']
    config_values['client_secret'] = token

    # Set the Airflow role that is assigned to the user when first registered in the database
    registration_role = os.getenv('AUTH_USER_REGISTRATION_ROLE')
    if registration_role is None:
        config_values['auth_user_registration_role'] = ""
    else:
        config_values['auth_user_registration_role'] = 'AUTH_USER_REGISTRATION_ROLE = "%s"' % registration_role

    # Prepare custom configuration
    config = openshift_oauth_config_template.substitute(**config_values)
    return config

custom_config = generate_openshift_oauth_config()

# Grab the default configuration template that comes with Airflow
site_packages_path = sysconfig.get_paths()["purelib"]
default_config_path = "%s/airflow/config_templates/default_webserver_config.py" % site_packages_path
with open(default_config_path, 'r') as file:
    default_config = file.read()

# Create the customized configuration
config_path = "%s/webserver_config.py" % os.getenv("AIRFLOW_HOME")
with open(config_path, 'w') as file:
    file.write(default_config)
    file.write(custom_config)

print("Custom webserver configuration written to %s" % config_path)
