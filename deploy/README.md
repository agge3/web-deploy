# Deployment instructions, notes, and scripts
 * `packages.ini`
   * package manifest that stores KVP mappings for each supported linux
     distribution's binary to respective package name in the package repository
 * `nginx.conf`
   * `nginx.conf` to be deployed on the server with each deployment. uses bash
     variables to be populated by envsubst (only for specifically named
     variables, to not conflict with post-deployment variables).
 * `gunicorn.service`
   * gunicorn systemd service file to be deployed on the server with each
     deployment. uses bash variables to be populated by envsubst (only for
     specifically named variables, to not conflict with post-deployment
     variables).
 * `env.sh`
   * global macros. source into a script's environment.
 * `deploy.sh`
   * idempotent deployment script. deploys fresh instances and updates existing
     instances.
