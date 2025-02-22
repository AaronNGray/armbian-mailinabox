#!/bin/bash

source setup/functions.sh
source /etc/mailinabox.conf # load global vars

echo "Installing Mail-in-a-Box system management daemon..."

# DEPENDENCIES

sudo apt-get install git build-essential libxml2-dev libxslt-dev libffi-dev libjpeg-dev


# virtualenv is used to isolate the Python 3 packages we
# install via pip from the system-installed packages.
#
# certbot installs EFF's certbot which we use to
# provision free TLS certificates.
#
# gcc and build tools are required to install the latest version
# of duplicity
apt_install python3-pip python3-gpg virtualenv certbot rsync librsync2 python3-fasteners python3-future python3-lockfile \
			gcc python3-dev librsync-dev gettext libjpeg-dev

apt_get_quiet remove --autoremove --purge duplicity || /bin/true

# install Cargo and Rust

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
. "$HOME/.cargo/env"


# Create a virtualenv for the installation of Python 3 packages
# used by the management daemon.
inst_dir=/usr/local/lib/mailinabox
mkdir -p $inst_dir
venv=$inst_dir/env
if [ ! -d $venv ]; then
	hide_output virtualenv -ppython3 $venv
elif [ ! -f $venv/.oscode ]; then
	echo "Re-creating Python environment..."
	rm -rf $venv
	hide_output virtualenv -ppython3 $venv
elif [ "$(cat $venv/.oscode)" != $(get_os_code) ]; then
	echo "Existing management environment is from an earlier version of the OS you're running."
	echo "Re-creating Python environment..."
	rm -rf $venv
	hide_output virtualenv -ppython3 $venv
fi

# Upgrade pip because the Ubuntu-packaged version is out of date.
hide_output $venv/bin/pip install --upgrade pip

# Duplicity does the actual backups.
# b2sdk is used for backblaze backups.
# boto3 is used for amazon aws backups.
# Both are installed outside the pipenv, so they can be used by duplicity
hide_output $venv/bin/pip install --upgrade bcrypt b2sdk boto3 "typer<0.5.0,>=0.4.1" "tomli<3.0.0,>=2.0.1" "rich<13.0.0,>=12.4.4" "httpx<0.24.0,>=0.23.0" "anyio<4.0.0,>=3.6.1" "nala" duplicity

# Install other Python 3 packages used by the management daemon.
# The first line is the packages that Josh maintains himself!
# NOTE: email_validator is repeated in setup/questions.sh, so please keep the versions synced.
hide_output $venv/bin/pip install --upgrade \
	rtyaml "email_validator>=1.0.0" "exclusiveprocess" \
	flask dnspython python-dateutil expiringdict gunicorn \
	qrcode[pil] pyotp pyopenssl \
	"idna" "cryptography" boto psutil postfix-mta-sts-resolver boto3 b2sdk

# Make the venv use the packaged gpgme bindings (the ones pip provides are severely out-of-date)
if [ ! -d $venv/lib/python$(python_version)/site-packages/gpg/ ]; then
	ln -s /usr/lib/python3/dist-packages/gpg/ $venv/lib/python$(python_version)/site-packages/
fi

echo $(get_os_code) > $venv/.oscode

# CONFIGURATION

# Create a backup directory and a random key for encrypting backups.
mkdir -p $STORAGE_ROOT/backup
if [ ! -f $STORAGE_ROOT/backup/secret_key.txt ]; then
	$(umask 077; openssl rand -base64 2048 > $STORAGE_ROOT/backup/secret_key.txt)
fi


# Download jQuery and Bootstrap local files

# Make sure we have the directory to save to.
assets_dir=$inst_dir/vendor/assets
rm -rf $assets_dir
mkdir -p $assets_dir

# jQuery CDN URL
jquery_version=3.6.1
jquery_url=https://code.jquery.com # Check this link for new versions

# Get jQuery
wget_verify $jquery_url/jquery-$jquery_version.min.js ea61688671d0c3044f2c5b2f2c4af0a6620ac6c2 $assets_dir/jquery.min.js

# Bootstrap CDN URL
# See https://github.com/twbs/bootstrap/releases to check for new versions
bootstrap_version=5.2.2
bootstrap_url=https://github.com/twbs/bootstrap/releases/download/v$bootstrap_version/bootstrap-$bootstrap_version-dist.zip

# Get Bootstrap
wget_verify $bootstrap_url 740b34c22cef5c2f12a34f084b813ea308fedf74 /tmp/bootstrap.zip
unzip -q /tmp/bootstrap.zip -d $assets_dir
mv $assets_dir/bootstrap-$bootstrap_version-dist $assets_dir/bootstrap
rm -f /tmp/bootstrap.zip

# FontAwesome CDN URL
# See https://github.com/FortAwesome/Font-Awesome/releases to check for new versions
fontawesome_version=6.2.1
fontawesome_url=https://github.com/FortAwesome/Font-Awesome/releases/download/$fontawesome_version/fontawesome-free-$fontawesome_version-web.zip

# Get FontAwesome
wget_verify $fontawesome_url cd0f2bcc9653b56e3e2dd82d6598aa6bbca8d796 /tmp/fontawesome.zip
unzip -q /tmp/fontawesome.zip -d $assets_dir
mv $assets_dir/fontawesome-free-$fontawesome_version-web $assets_dir/fontawesome
rm -f /tmp/fontawesome.zip

# Create an init script to start the management daemon and keep it
# running after a reboot.
# Set a long timeout since some commands take a while to run, matching
# the timeout we set for PHP (fastcgi_read_timeout in the nginx confs).
# Note: Authentication currently breaks with more than 1 gunicorn worker.
cat > $inst_dir/start <<EOF;
#!/bin/bash
# Set character encoding flags to ensure that any non-ASCII don't cause problems.
export LANGUAGE=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_TYPE=en_US.UTF-8

mkdir -p /var/lib/mailinabox
tr -cd '[:xdigit:]' < /dev/urandom | head -c 32 > /var/lib/mailinabox/api.key
chmod 640 /var/lib/mailinabox/api.key

source $venv/bin/activate
export PYTHONPATH=$(pwd)/management
exec gunicorn -b localhost:10222 -w 1 --timeout 630 wsgi:app
EOF
chmod +x $inst_dir/start
cp --remove-destination conf/mailinabox.service /lib/systemd/system/mailinabox.service # target was previously a symlink so remove it first
hide_output systemctl link -f /lib/systemd/system/mailinabox.service
hide_output systemctl daemon-reload
hide_output systemctl enable mailinabox.service

# Perform nightly tasks at 3am in system time: take a backup, run
# status checks and email the administrator any changes.

minute=$((RANDOM % 60))  # avoid overloading mailinabox.email
cat > /etc/cron.d/mailinabox-nightly << EOF;
# Mail-in-a-Box --- Do not edit / will be overwritten on update.
# Run nightly tasks: backup, status checks.
$minute 3 * * *	root	(cd $(pwd) && management/daily_tasks.sh)
EOF

# Start the management server.
restart_service mailinabox

# FOR DEVELOPMENT PURPOSES ONLY:
# If there is a CA certificate in the folder, install it.
# MIAB will only accept a manual certificate installation
# if it is signed by a CA trusted by it.
if [[ -f mailinabox-ca.crt ]]; then
    echo "Custom CA certificate detected. Installing..."
    rm -f /usr/local/share/ca-certificates/mailinabox-ca.crt
    cp mailinabox-ca.crt /usr/local/share/ca-certificates/
    hide_output update-ca-certificates --fresh
fi
