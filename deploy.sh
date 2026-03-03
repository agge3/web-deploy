#!/usr/bin/env bash
#
# deploy to remote based on credentials. supports fresh deployments and update
# deployments. deployment is idempotent to reflect state of github repo and not
# depend on server state.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# deploy environment - shared utility and variables
source "$SCRIPT_DIR/env.sh"
# credentials environment - credential variables
source "$(git rev-parse --show-toplevel)/credentials/env.sh"

REPO_SSH="git@github.com:CSC-648-SFSU/csc648-sp26-145-team16.git"
# repository target directory name
REPO_DIR="repo"
APP_HOME="/home/$APP_USER"
VENV_DIR="$APP_HOME/$REPO_DIR/venv"
PY_DIR="$REPO_DIR/application/backend"
NODE_DIR="$REPO_DIR/application/frontend"
# package mappings for each supported distribution
MANIFEST="$SCRIPT_DIR/packages.ini"
# deploy remotely over ssh
SSHPASS_DEPLOY=false
DISTRO=""
VERSION=false
UPDATE=false
GUNICORN_SERVICE="/etc/systemd/system/gunicorn.service"
RET=0
# APP_USER HOME ssh directory
APP_SSH="$APP_HOME/.ssh"
# deploy private key name
KEY_BASE="$(basename "$DEPLOY_PRIV_KEY_F")"
# git command over ssh (with deploy key) prefix
GIT_SSH="GIT_SSH_COMMAND='ssh -i $APP_SSH/$KEY_BASE -o StrictHostKeyChecking=no'"
SSHKEY_DEPLOY=false

usage() {
	echo "Usage: $(basename "$0") [-h] [-v] [-s] [-d distro] [-u] [-k]"
	echo "  -h  give this help list"
	echo "  -v  print package versions of this deployment"

	echo "  -s  use sshpass for remote deployment"
	echo "  -d  override distro detection (ubuntu|debian|fedora|arch)"
	echo "  -u  system update target"
	echo "  -k	use ssh with credentials key file (csc648-shared) for remote \
deployment (overrides '-s')"
}

# Detect distribution of target.
detect_distro() {
	local distro
	distro=$(cmd_as "$ROOT_UNAME" "awk -F= '/^ID=/{print \$2}' /etc/os-release")
	if [[ -z "$distro" ]]; then
		elog "cannot detect distro"
		return 1
	fi
	echo "$distro"
}

# Run a command as a given user, locally or remotely.
cmd_as() {
	local user="$1"
	shift
	# NOTE: for remote deployment, `StrictHostKeyChecking=no` for no
	# confirmation prompt of first remote host connection
	if [[ "$SSHKEY_DEPLOY" == true ]]; then
		local encoded
		encoded=$(echo "$*" | base64 -w0)
		# ssh as root, so don't need password to sudo to target user
		ssh -i "$PRIV_KEY_F" -o StrictHostKeyChecking=no "$ROOT_UNAME@$MY_HOSTNAME" \
			"echo $encoded | base64 -d | sudo -iu $user bash"
	elif [[ "$SSHPASS_DEPLOY" == true ]]; then
		# base64 encode the cmd, to avoid nested quotes. disable line wrapping -
		# encode the entire string (for long heredoc strings).
		local encoded
		encoded=$(echo "$*" | base64 -w0)
		sshpass -p "$ROOT_PWD" ssh -o StrictHostKeyChecking=no "$ROOT_UNAME@$MY_HOSTNAME" \
			"echo $encoded | base64 -d | sudo -S -iu $user bash"
	else
		echo "$ROOT_PWD" | sudo -S -iu "$user" bash -c "$*"
	fi
}

# `scp` wrapper to switch between key and password auth for `scp`.
my_scp() {
	local src="$1"
	local dst="$2"
	if [[ $SSHKEY_DEPLOY == true ]]; then
		scp -r -i "$PRIV_KEY_F" -o StrictHostKeyChecking=no \
			"$src" "$ROOT_UNAME@$MY_HOSTNAME:$dst"
	elif [[ $SSHPASS_DEPLOY == true ]]; then
		sshpass -p "$ROOT_PWD" scp -r -o StrictHostKeyChecking=no \
			"$src" "$ROOT_UNAME@$MY_HOSTNAME:$dst"
	fi
}

# manifest parser
# USAGE: manifest <section> <key>
# NOTE: assumes manifest implementation is ini
# CREDIT: Generated with Claude Opus 4.6 by Anthropic
manifest_get() {
	local section="$1" key="$2"
	local in_section=false
	while IFS= read -r line; do
		line="${line%%#*}"
		line="${line// /}"
		[[ -z "$line" ]] && continue
		if [[ "$line" == "[$section]" ]]; then
			in_section=true
			continue
		elif [[ "$line" == \[*\] ]]; then
			in_section=false
			continue
		fi
		if [[ "$in_section" == true ]]; then
			local k="${line%%=*}" v="${line##*=}"
			if [[ "$k" == "$key" ]]; then
				echo "$v"
				return 0
			fi
		fi
	done <"$MANIFEST"
	return 1
}

# Resolve canonical package name to distro-specific name.
pkg_name() {
	local name
	if name=$(manifest_get "$DISTRO" "$1"); then
		echo "$name"
	else
		elog "no package mapping for '$1' on '$DISTRO'"
		exit 1
	fi
}

# Resolve a binary from a list of known candidates.
# usage: resolve_bin python3 python
resolve_bin() {
	for name in "$@"; do
		if cmd_as "$ROOT_UNAME" "command -v $name" &>/dev/null; then
			echo "$name"
			return 0
		fi
	done
	return 1
}

# wrapper for checking version and recording "NOT INSTALLED" gracefully
ver() {
	local result
	fail="NOT INSTALLED"
	if result=$(cmd_as "$@" 2>&1); then
		if [[ -z "$result" ]]; then
			echo "$fail"
		else
			echo "$result"
		fi
	else
		echo "$fail"
	fi
}

# parse args:
while getopts "hvsd:uk:" opt; do
	case $opt in
	v) VERSION=true ;;
	s) SSHPASS_DEPLOY=true ;;
	d) DISTRO="$OPTARG" ;;
	u) UPDATE=true ;;
	k)
		# only one method of ssh deploy allowed
		SSHKEY_DEPLOY=true
		SSHPASS_DEPLOY=false
		;;
	h)
		usage
		exit 0
		;;
	*)
		usage
		exit 1
		;;
	esac
done

if [[ -z "$DISTRO" ]]; then
	DISTRO="$(detect_distro)"
fi

ilog "distro: $DISTRO"

# Install packages using the distro's package manager.
PKG_INSTALL=""
# Check if a package is installed.
PKG_INSTALLED=""

# determine package manager now that distro is known
case "$DISTRO" in
ubuntu | debian)
	PKG_INSTALLED="dpkg -s"
	PKG_INSTALL="apt install -y"
	if [[ $UPDATE == true ]]; then
		cmd_as "$ROOT_UNAME" "apt update -y && apt upgrade -y"
	fi
	;;
fedora)
	PKG_INSTALLED="rpm -q"
	PKG_INSTALL="dnf install -y"
	if [[ $UPDATE == true ]]; then
		cmd_as "$ROOT_UNAME" "dnf update -y"
	fi
	;;
arch)
	PKG_INSTALLED="pacman -Q"
	PKG_INSTALL="pacman -S --noconfirm"
	if [[ $UPDATE == true ]]; then
		cmd_as "$ROOT_UNAME" "pacman -Syu --noconfirm"
	fi
	;;
*)
	elog "unsupported distro: $DISTRO"
	exit 1
	;;
esac

# root check (skip for remote):
if [[ "$SSHPASS_DEPLOY" == false && $EUID -ne 0 ]]; then
	elog "must be ran as superuser if local"
	exit 1
fi

# required packages
PKGS=(
	mysql-server
	mysql-client
	python
	python-pip
	python-venv
	nginx
	git
	nodejs
	npm
	certbot
	python3-certbot-nginx
)

# check if required packages are installed
for canonical in "${PKGS[@]}"; do
	actual=$(pkg_name "$canonical")
	if ! cmd_as "$ROOT_UNAME" "$PKG_INSTALLED" "$actual"; then
		ilog "package missing: $actual. installing..."
		if ! cmd_as "$ROOT_UNAME" "$PKG_INSTALL" "$actual"; then
			elog "package install failed: $actual"
			exit 1
		fi
	fi
done

# resolve binaries after install
PYTHON=$(resolve_bin python3 python)
MYSQL=$(resolve_bin mysql mariadb)

# version check:
if [[ "$VERSION" == true ]]; then
	ilog "OS: $(ver "$ROOT_UNAME" "grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"'")"
	ilog "PYTHON: $(ver "$ROOT_UNAME" "$PYTHON --version")"
	ilog "MYSQL: $(ver "$ROOT_UNAME" "$MYSQL -V")"
	ilog "NGINX: $(ver "$ROOT_UNAME" "nginx -v 2>&1")"
	ilog "NODE: $(ver "$ROOT_UNAME" "node --version")"
	ilog "NPM: $(ver "$ROOT_UNAME" "npm --version")"
	ilog "GUNICORN: $(ver "$APP_USER" "source $VENV_DIR/bin/activate && gunicorn --version")"
	ilog "FLASK: $(ver "$APP_USER" "source $VENV_DIR/bin/activate && python -c 'from importlib.metadata import version; print(version(\"flask\"))'")"
	ilog "SQLALCHEMY: $(ver "$APP_USER" "source $VENV_DIR/bin/activate && python -c 'import sqlalchemy; print(sqlalchemy.__version__)'")"
	ilog "CERTBOT: $(ver "$ROOT_UNAME" "certbot --version")"
	ilog "ESLINT: $(ver "$APP_USER" "cd $NODE_DIR && npx eslint --version")"
	ilog "PRETTIER: $(ver "$APP_USER" "cd $NODE_DIR && npx prettier --version")"
	ilog "REACT: $(ver "$APP_USER" "cd $NODE_DIR && node -e \"console.log(require('react/package.json').version)\"")"
	ilog "VITE: $(ver "$APP_USER" "cd $NODE_DIR && npx vite --version")"
	exit 0
fi

# validate users:
# check if APP_USER exists and create if not
if ! cmd_as "$ROOT_UNAME" "id $APP_USER &>/dev/null"; then
	ilog "creating app user: $APP_USER"
	cmd_as "$ROOT_UNAME" "useradd -m -s /bin/bash $APP_USER"
fi

# check if DB_USER exists and create if not
if ! cmd_as "$ROOT_UNAME" "id $DB_USER &>/dev/null"; then
	ilog "creating db user: $DB_USER"
	cmd_as "$ROOT_UNAME" "useradd -s /bin/bash $DB_USER"
fi

# validate app:
# check if repo exists and setup if not
if ! cmd_as "$APP_USER" "test -d $REPO_DIR"; then
	# NOTE: if repository directory is not found, then ASSUME REMOTE and remote
	# bootstrap repository
	ilog "repository directory not found: $REPO_DIR. creating..."
	# APP_USER HOME ssh directory must exist
	if ! cmd_as "$APP_USER" "test -d $APP_SSH"; then
		ilog "$APP_USER ssh directory not found: $APP_SSH. creating..."
		if ! cmd_as "$APP_USER" "mkdir -p $APP_SSH"; then
			RET=$?
			elog "mkdir -p $APP_SSH failed: RET: $RET"
			exit $?
		fi
	fi
	# APP_USER needs github deploy key to git over ssh (private repo, can't use
	# https).
	if ! cmd_as "$APP_USER" "test -f $APP_SSH/$KEY_BASE"; then
		ilog "deploy key not found: $APP_SSH/$KEY_BASE. copying to $APP_SSH..."
		my_scp "$DEPLOY_PRIV_KEY_F" "$APP_SSH"
		# set correct permissions for ssh key
		cmd_as "$ROOT_UNAME" \
			"chown $APP_USER:$APP_USER $APP_SSH/$KEY_BASE && chmod 600 $APP_SSH/$KEY_BASE"
	fi

	# OK to clone repo
	cmd_as "$APP_USER" "$GIT_SSH git clone $REPO_SSH $REPO_DIR"
# repo exists: update existing repo
else
	ilog "repo exists, updating to main..."
	cmd_as "$APP_USER" "$GIT_SSH git -C $REPO_DIR fetch origin main"
	cmd_as "$APP_USER" "$GIT_SSH git -C $REPO_DIR reset --hard origin/main"
fi

# validate python:
# check if python venv exists and create if not
if ! cmd_as "$APP_USER" "test -d $VENV_DIR"; then
	ilog "python virtual environment not found: $VENV_DIR. creating..."
	cmd_as "$APP_USER" "$PYTHON -m venv $VENV_DIR"
fi

# check if there's a requirements.txt to install
# NOTE: python dependencies MUST be in a requirements.txt. infra assumes that's
# how it will be informed
if cmd_as "$APP_USER" "test -f $PY_DIR/requirements.txt"; then
	# always install requirements.txt on every deploy, to catch repo updates
	ilog "found python requirements: $PY_DIR/requirements.txt. installing..."
	cmd_as "$APP_USER" \
		"source $VENV_DIR/bin/activate && pip install -r $PY_DIR/requirements.txt"
fi

# validate node:
# check if there's a package.json to install
if cmd_as "$APP_USER" "test -f $NODE_DIR/package.json"; then
	# always install package.json on every deploy, to catch repo updates
	ilog "found node requirements: $NODE_DIR/package.json. installing..."
	cmd_as "$APP_USER" "cd $NODE_DIR && npm install"
fi

# build frontend:
# build locally, ship artifacts
if [[ $SSHKEY_DEPLOY == true || $SSHPASS_DEPLOY == true ]]; then
	ilog "building frontend locally..."

	# build in subshell, to not pollute environment
	(
		cd "$(git rev-parse --show-toplevel)/application/frontend"
		npm install
		npm run build
	)

	ilog "shipping build to remote..."
	my_scp \
		"$(git rev-parse --show-toplevel)/application/frontend/dist" \
		"$APP_HOME/$NODE_DIR/dist"

	# give APP_USER ownership, after ROOT_USER deployed
	cmd_as "$ROOT_UNAME" "chown -R $APP_USER:$APP_USER $APP_HOME/$NODE_DIR/dist"
# build on server
# WARNING: SERVER NEEDS ADEQUATE RESOURCES!!!
else
	if cmd_as "$APP_USER" "test -f $NODE_DIR/package.json"; then
		ilog "building frontend on server..."
		cmd_as "$APP_USER" "cd $NODE_DIR && npm install && npm run build"
	fi
fi

# validate db:
# run db with init
cmd_as "$ROOT_UNAME" "systemctl enable --now mysql || systemctl enable --now mariadb"

# check if db has tables, create db over UNIX socket if not
if ! cmd_as "$DB_USER" "$MYSQL -e 'SELECT 1'" &>/dev/null; then
	ilog "creating mysql user: $DB_USER (auth_socket)"
	cmd_as "$ROOT_UNAME" \
		"$MYSQL -e \"CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED WITH auth_socket; FLUSH PRIVILEGES;\""
fi

# check if db has an admin user, assign as DB_UNAME if not
if ! cmd_as "$DB_USER" "$MYSQL -e \"USE $DB_UNAME\"" &>/dev/null; then
	# xxx this proceeds even though database already exists!
	ilog "creating database: $DB_NAME"
	# xxx guard on db level too
	cmd_as "$ROOT_UNAME" \
		"$MYSQL -e \"CREATE DATABASE IF NOT EXISTS $DB_NAME; GRANT ALL PRIVILEGES ON $DB_UNAME.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;\""
fi

# idempotent deploy nginx (always take repo as source of truth):
NGINX_CONF="/etc/nginx/sites-available/$APP_USER"
NGINX_ENABLED="/etc/nginx/sites-enabled/$APP_USER"
# export for envsubst
export APP_USER APP_HOME NODE_DIR MY_HOSTNAME
NGINX_VARS='$APP_USER $APP_HOME $NODE_DIR $MY_HOSTNAME'

# remove default if it exists
if ! cmd_as "$ROOT_UNAME" "test -f $NGINX_CONF"; then
	cmd_as "$ROOT_UNAME" "rm -f /etc/nginx/sites-enabled/default"
fi

# deploy nginx config from repo
ilog "installing nginx config..."
envsubst "$NGINX_VARS" <"$SCRIPT_DIR/nginx.conf" >/tmp/nginx.conf
my_scp /tmp/nginx.conf "$NGINX_CONF"
rm /tmp/nginx.conf
if ! cmd_as "$ROOT_UNAME" "test -L $NGINX_ENABLED"; then
	cmd_as "$ROOT_UNAME" "ln -s $NGINX_CONF $NGINX_ENABLED"
fi

# add nginx (www-data) to APP_USER group, so nginx can serve APP_USER files
cmd_as "$ROOT_UNAME" "usermod -aG $APP_USER www-data"

# open any closed ports on the OS level
# WARNING: VALIDATE THEY'RE ALSO OPEN ON THE CLOUD PROVIDER LEVEL!!!
cmd_as "$ROOT_UNAME" "ufw allow 80 && ufw allow 443"

# run nginx config checks and restart
cmd_as "$ROOT_UNAME" "nginx -t && systemctl restart nginx"

# idempotent deploy gunicorn (always take repo as source of truth):
# export for envsubst
export APP_USER APP_HOME VENV_DIR PY_DIR
GUNICORN_VARS='$APP_USER $APP_HOME $VENV_DIR $PY_DIR'

# deploy gunicorn service from repo
ilog "installing gunicorn service..."
envsubst "$GUNICORN_VARS" <"$SCRIPT_DIR/gunicorn.service" >/tmp/gunicorn.service
my_scp /tmp/gunicorn.service "$GUNICORN_SERVICE"
rm /tmp/gunicorn.service
cmd_as "$ROOT_UNAME" "systemctl daemon-reload"

# run gunicorn service with init
cmd_as "$ROOT_UNAME" "systemctl enable gunicorn && systemctl restart gunicorn"

# xxx also add certbot and distribute an envsubst cronjob template for it

ilog "SUCCESS"
exit 0
