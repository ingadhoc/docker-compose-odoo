#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# This is required since we are running as sudo
REAL_USER="${HOME##*/}"

cp $DIR/.prompt_git ${HOME}

cd
chown ${REAL_USER}:${REAL_USER} .prompt_git
echo "source \${HOME}/.prompt_git" >> .bashrc
source .bashrc
