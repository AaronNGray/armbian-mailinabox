


setup_dir=/usr/local/lib/setup
mkdir -p $setup_dir
setup_venv=$setup_dir/env
if [ ! -d $setup_venv ]; then
	hide_output virtualenv -ppython3 $setup_venv
fi

# Installing email_validator is repeated in setup/management.sh, but in setup/management.sh
# we install it inside a virtualenv. In this script, we don't have the virtualenv yet
# so we install the python package globally.
hide_output $venv/bin/pip install --upgrade "email_validator>=1.0.0" || exit 1
