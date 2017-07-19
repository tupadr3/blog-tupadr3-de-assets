#!/bin/bash
#                                                                
# Scaleway setup script

#################################
# host
#################################

if [ "$(hostname)" == 'dev.tupadr3.de' ]; then
   echo "Setting up dev.tupadr3.de"
else 
    echo "Hostname doesn't match dev.tupadr3.de"
    exit 0
fi

#################################
# install
#################################

apt-get update -y && apt-get upgrade -y

apt-get install -y ssh openssl openssh-server locate aptitude ntp ntpdate \
    ufw bridge-utils apt-transport-https \
    htop nload curl wget \
    putty-tools joe 

# udev was necessary as the base image didn't install it by default
apt-get install -y udev

#################################
# basics
#################################

# set timezone
timedatectl set-timezone "Europe/Amsterdam"
dpkg-reconfigure -f noninteractive tzdata

# check locale & make sure the correct local is selected. In my case de_DE.UTF-8
cp /etc/locale.gen /etc/locale.gen.sav
sed -i 's/^# de_DE.UTF-8/de_DE.UTF-8/g' /etc/locale.gen
dpkg-reconfigure -f noninteractive locales
export LANGUAGE=de_DE.UTF-8
export LANG=de_DE.UTF-8

# upd8 locate db in order to be able to search for files
updatedb

# remove joe backup feature. Joe is my editor of joice
sed -i 's/\s-nobackups/-nobackups/g' /etc/joe/joerc

# create basic folder structure
mkdir -p /data/backup          > /dev/null 2>&1
mkdir -p /data/logs/cron       > /dev/null 2>&1
mkdir -p /data/config/scripts  > /dev/null 2>&1
mkdir -p /data/config/ssh      > /dev/null 2>&1
mkdir -p /data/docker          > /dev/null 2>&1
mkdir -p /data/www             > /dev/null 2>&1
mkdir -p /data/www/html        > /dev/null 2>&1
mkdir -p /data/temp            > /dev/null 2>&1

# keep locate database up2d8
echo "0 * * * *   root   /usr/bin/updatedb > /data/logs/cron/updatedb" > /etc/cron.d/locate
echo "" >> /etc/cron.d/locate

# bash coloring & alias
sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/g' ~/.bashrc
echo "alias ll='ls $LS_OPTIONS -lah'" >> ~/.bashrc
echo "export PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\H\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '" >> ~/.bashrc

# reload bashrc script
. ~/.bashrc

#################################
# ssh
#################################

# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# !!! a empty passphrase is not recommend for production environments !!!!
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

# setup keyless ssh-auth & add empty passphrase
cd ~
mkdir .ssh > /dev/null 2>&1
ssh-keygen -t rsa -b 4096 -C "root@`hostname`" -f ~/.ssh/id_rsa -N ""

# prep for passwordless login
chown -R $USER:$USER .ssh
chmod 700 .ssh

# backup current authorized_keys
cp .ssh/authorized_keys .ssh/authorized_keys.`date +%Y%m%d`

# for scaleway we need the key to be in instance_keys and authorized_keys
cat .ssh/id_rsa.pub >> .ssh/instance_keys
cat .ssh/id_rsa.pub >> .ssh/authorized_keys
chmod 600 .ssh/authorized_keys

# copy ssh files for backup and generate putty ppk
cp .ssh/id_rsa /data/config/ssh/`hostname`.key
cp .ssh/id_rsa.pub /data/config/ssh/`hostname`.pub

# generate ppk keys to able to use winscp and putty
puttygen .ssh/id_rsa -o /data/config/ssh/`hostname`.ppk

# ssh config changes in order to only allow login with ssh-keys and change port to 2605
sed -i 's/^#AuthorizedKeysFile/AuthorizedKeysFile/g' /etc/ssh/sshd_config
sed -i 's/^Port\s22/Port 2605/g' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication\sno/PasswordAuthentication no/g' /etc/ssh/sshd_config

# reaload ssh deamon in order to test the login from another ssh session
/etc/init.d/ssh restart

#################################
# sysctl
#################################
mv /etc/sysctl.conf /etc/sysctl.conf.s`date +%Y%m%d`
cat << EOF > /etc/sysctl.conf
# sysctl config
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

# reload settings
sysctl -p

#################################
# postfix
#################################

DEBIAN_FRONTEND=noninteractive apt-get install -y postfix sasl2-bin libsasl2-modules popa3d mailutils

# make a backup
cp /etc/postfix/main.cf /etc/postfix/main.cf.`date +%Y%m%d`

sed -i 's/^relayhost/#relayhost/g' /etc/postfix/main.cf
sed -i 's/^myhostname/#myhostname/g' /etc/postfix/main.cf
echo "myhostname = `hostname`" >> /etc/postfix/main.cf
echo "smtp_use_tls = yes" >> /etc/postfix/main.cf
echo "smtp_sasl_auth_enable = yes" >> /etc/postfix/main.cf
echo "smtp_sasl_password_maps = hash:/etc/postfix/sasl/smtp_auth" >> /etc/postfix/main.cf
echo "smtp_sasl_security_options = noanonymous" >> /etc/postfix/main.cf
echo "smtp_header_checks = regexp:/etc/postfix/header_checks" >> /etc/postfix/main.cf

# relay host & auth. Add your credentials here 
echo "relayhost = smtp.xxxxx.de:587" >> /etc/postfix/main.cf
echo "smtp.1und1.de dev@tupadr3.de:xxxxxxxxxx" >> /etc/postfix/sasl/smtp_auth

# rewrites to know from which server the mail is coming from 
echo "/^From:*/     REPLACE From: `hostname` <server@tupadr3.de>" >> /etc/postfix/header_checks

# postmap & restart
postmap /etc/postfix/sasl/smtp_auth
/etc/init.d/postfix restart

# send test mail
echo "This will go into the body of the mail." | mail -s "Test E-mail" dev@tupadr3.de

#################################
# docker
#################################
apt-get install -y apt-transport-https ca-certificates gnupg2 software-properties-common
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -
add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/debian \
   $(lsb_release -cs) \
   stable"
apt-get update && apt-get install docker-ce -y


# docker daemon settings
echo "{" > /etc/docker/daemon.json
echo "\"storage-driver\": \"overlay2\"", >> /etc/docker/daemon.json
echo "\"ipv6\": false," >> /etc/docker/daemon.json
echo "\"iptables\": false" >> /etc/docker/daemon.json
echo "}" >> /etc/docker/daemon.json

service docker restart

#################################
# docker-compose
#################################

# Setup docker-compose
COMPOSE_VERSION=`curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4`
echo "Installing docker-compose $COMPOSE_VERSION"
curl -L "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" > /usr/local/bin/docker-compose
chown root:root /usr/local/bin/docker-compose
chmod 755 /usr/local/bin/docker-compose

#################################
# firewall
#################################

apt-get install ufw -y
sed -i s/DEFAULT_INPUT_POLICY=\"DROP\"/DEFAULT_INPUT_POLICY=\"ACCEPT\"/ /etc/default/ufw
sed -i s/DEFAULT_FORWARD_POLICY=\"DROP\"/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/ /etc/default/ufw
sed -i s/IPV6=yes/IPV6=no/ /etc/default/ufw
sed -i s/COMMIT/#COMMIT/ /etc/ufw/after.rules

# nat rulz for docker internet access
echo "# NAT table rules" >> /etc/ufw/before.rules
echo "*nat" >> /etc/ufw/before.rules
echo ":POSTROUTING ACCEPT [0:0]" >> /etc/ufw/before.rules

# this rule gives all docker briged networks web access. 172.18.0.0/16 would only allow the
# first bridge generated by docker (depending on the network docker is configured to use)
echo "-A POSTROUTING -s 172.0.0.0/8 ! -o docker0 -j MASQUERADE" >> /etc/ufw/before.rules
echo "COMMIT" >> /etc/ufw/before.rules

# drop any input left
echo "-A ufw-reject-input -j DROP" >> /etc/ufw/after.rules
echo "COMMIT" >> /etc/ufw/after.rules

# setup basic ufw to allow ssh access
ufw allow 2605/tcp

ufw disable && ufw --force enable 

#################################
# let's encrypt basic dirs for 
#################################
mkdir -p /data/www/letsencrypt -p
mkdir -p /data/config/scripts -p
chown www-data:www-data /data/www/letsencrypt/ -R

#################################
# dhparam
#################################
mkdir -p /data/config/nginx/assets

# in case we dont have on already we may need to create the dhparam file 
if [ ! -f /data/config/nginx/assets/dhparam.pem ]; then
   openssl dhparam -out /data/config/nginx/assets/dhparam.pem 2048
fi

#################################
# backup
#################################
BORG_VERSION=`curl -s https://api.github.com/repos/borgbackup/borg/releases/latest | grep tag_name | cut -d '"' -f 4`
echo "Installing borg-backup $BORG_VERSION"
curl -L "https://github.com/borgbackup/borg/releases/download/$BORG_VERSION/borg-linux64" > /usr/local/bin/borg
chown root:root /usr/local/bin/borg
chmod 755 /usr/local/bin/borg

echo "Setting up `hostname` done"