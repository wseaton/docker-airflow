#!/usr/bin/env bash
set -x
TRY_LOOP="20"

: "${REDIS_HOST:="redis"}"
: "${REDIS_PORT:="6379"}"
: "${REDIS_PASSWORD:=""}"

: "${DB_TYPE:="postgres"}"
if [ "$DB_TYPE" = "mysql" ];then
: "${SQL_HOST:="mysql"}"
: "${SQL_PORT:="3306"}"
: "${SQL_USER:="airflow"}"
: "${SQL_PASSWORD:="airflow"}"
: "${SQL_DB:="airflow"}"
else
 : "${SQL_HOST:="postgres"}"
 : "${SQL_PORT:="5432"}"
 : "${SQL_USER:="airflow"}"
 : "${SQL_PASSWORD:="airflow"}"
 : "${SQL_DB:="airflow"}"
fi

# Defaults and back-compat
: "${AIRFLOW__CORE__FERNET_KEY:=${FERNET_KEY:=DlMltFwFwXlvp9SGh27VQ_nCkCm6-0wugA2Tb-YVgr8=}}"
: "${AIRFLOW__CORE__EXECUTOR:=${EXECUTOR:-Sequential}Executor}"

export \
  AIRFLOW__CELERY__BROKER_URL \
  AIRFLOW__CELERY__RESULT_BACKEND \
  AIRFLOW__CORE__EXECUTOR \
  AIRFLOW__CORE__FERNET_KEY \
  AIRFLOW__CORE__LOAD_EXAMPLES \
  AIRFLOW__CORE__SQL_ALCHEMY_CONN \
  C_FORCE_ROOT



# Load DAGs exemples (default: Yes)
if [[ -z "$AIRFLOW__CORE__LOAD_EXAMPLES" && "${LOAD_EX:=n}" == n ]]
then
  AIRFLOW__CORE__LOAD_EXAMPLES=False
fi

# Install custom python package if requirements.txt is present
if [ -e "/requirements.txt" ]; then
    $(which pip) install --user -r /requirements.txt
fi

if [ -n "$REDIS_PASSWORD" ]; then
    REDIS_PREFIX=:${REDIS_PASSWORD}@
else
    REDIS_PREFIX=
fi

wait_for_port() {
  local name="$1" host="$2" port="$3"
  local j=0
  while ! timeout 3 nc -z "$host" "$port" >/dev/null 2>&1 < /dev/null; do
    j=$((j+1))
    if [ $j -ge $TRY_LOOP ]; then
      echo >&2 "$(date) - $host:$port still not reachable, giving up"
      exit 1
    fi
    echo "$(date) - waiting for $name... $j/$TRY_LOOP"
    sleep 5
  done
}

import_ca_certs() {
  local bundle="$1"
  if [ -e "$bundle" ]; then
    local tmpdir=$(mktemp -d)
    # Break the CA bundle into individual cert files
    awk "BEGIN {c=0;} /BEGIN CERT/{c++} { print > \"$tmpdir/cert.\" c \".crt\"}" < "$bundle"
    # Add the certs to the trust store
    update-ca-certificates --localcertsdir $tmpdir || exit 1
  fi
}

configure_auth() {
  if [ "$AUTH_TYPE" = openshift ]; then
    # Import Kubernetes certificates into trust store. This is required for the login with OpenShift to work.
    # It allows Airflow to connect to the openshift.default.svc.cluster.local and oauth-openshift.apps.<cluster_domain>
    # endpoints while executing the OAuth authorization code flow.
    import_ca_certs /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  fi
}

if [ "$AIRFLOW__CORE__EXECUTOR" != "SequentialExecutor" ]; then
  if [ "$DB_TYPE" = "mysql" ];then
    AIRFLOW__CORE__SQL_ALCHEMY_CONN="mysql://$SQL_USER:$SQL_PASSWORD@$SQL_HOST:$SQL_PORT/$SQL_DB"
    AIRFLOW__CELERY__RESULT_BACKEND="db+mysql://$SQL_USER:$SQL_PASSWORD@$SQL_HOST:$SQL_PORT/$SQL_DB"
  else
    AIRFLOW__CORE__SQL_ALCHEMY_CONN="postgresql+psycopg2://$SQL_USER:$SQL_PASSWORD@$SQL_HOST:$SQL_PORT/$SQL_DB"
    AIRFLOW__CELERY__RESULT_BACKEND="db+postgresql://$SQL_USER:$SQL_PASSWORD@$SQL_HOST:$SQL_PORT/$SQL_DB"
  fi
  wait_for_port "$DB_TYPE" "$SQL_HOST" "$SQL_PORT"
fi
echo "export AIRFLOW__CORE__SQL_ALCHEMY_CONN=${AIRFLOW__CORE__SQL_ALCHEMY_CONN}" >> ~/.profile

if [ "$AIRFLOW__CORE__EXECUTOR" = "CeleryExecutor" ]; then
  AIRFLOW__CELERY__BROKER_URL="redis://$REDIS_PREFIX$REDIS_HOST:$REDIS_PORT/1"
  wait_for_port "Redis" "$REDIS_HOST" "$REDIS_PORT"
  # Celery worker refuses to run when executed as gid=0 egid=0 on OpenShift. Set C_FORCE_ROOT to override the check.
  C_FORCE_ROOT=True
fi

case "$1" in
  webserver)
    airflow upgradedb
    if [ "$AIRFLOW__CORE__EXECUTOR" = "LocalExecutor" ]; then
      # With the "Local" executor it should all run in one container.
      airflow scheduler &
    fi
    configure_auth
    exec airflow "$@"
    ;;
  scheduler)
    # To give the webserver time to run upgradedb.
    sleep 20
    exec airflow "$@"
    ;;
  worker)
    # To give the webserver time to run upgradedb.
    sleep 20
    exec airflow "$@"
    ;;
  flower)
    sleep 10
    exec airflow "$@"
    ;;
  version)
    exec airflow "$@"
    ;;
  *)
    # The command is something like bash, not an airflow subcommand. Just run it in the right environment.
    exec "$@"
    ;;
esac
