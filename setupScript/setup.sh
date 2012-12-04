#!/bin/sh

#Stupid non-updated VMs
sudo apt-get -q update

#Need to set swappines
echo 10 | sudo tee /proc/sys/vm/swappiness
hasSwappiness=`grep "vm.swappiness" /etc/sysctl.conf`
if [ -z "$hasSwappiness" ]; then
  echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf
else
  sudo sed -i -e 's/vm.swappiness=.*/vm.swappiness=10/' /etc/sysctl.conf
fi

#Getting java install started now
sudo apt-get -qy install openjdk-6-jdk &
javaInstall=$!

#TODO: Check if java install kicks back after ~a second and check error code, then update if need be instead of at start

bigtopMirror=http://archive.apache.org/dist/
if [ -n "$1" ]; then
  if wget -qO- $1 | grep "bigtop" >> /dev/null 2>&1; then
    apacheMirror=$1
  fi
fi

if [ -z $apacheMirror ]; then
  #Getting a bigtop mirror
  apacheMirror=`wget -qO- "http://www.apache.org/dyn/closer.cgi/" | grep -A 2 "We suggest" | tail -n 1 | cut -d '"' -f2`
fi

#And bigtop gpg key
wget -O- $bigtopMirror/incubator/bigtop/bigtop-0.3.0-incubating/repos/GPG-KEY-bigtop | sudo apt-key add -

bigtopFile=/etc/apt/sources.list.d/bigtop.list

#populating apt with our bigtop file
echo "deb $bigtopMirror/incubator/bigtop/bigtop-0.3.0-incubating/repos/ubuntu bigtop contrib" | sudo tee $bigtopFile

#need to wait for first apt install to finish before more apt installs
wait $javaInstall
JAVA_HOME=`readlink -f \`which java\``
JAVA_HOME=`dirname $JAVA_HOME`
JAVA_HOME=`dirname $JAVA_HOME`

echo "JAVA_HOME=$JAVA_HOME" >> ~/.profile
export JAVA_HOME=$JAVA_HOME

sudo apt-get -q update -o Dir::Etc::sourcelist="sources.list.d/bigtop.list" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"

#Full hadoop and zookeeper install, immediately interacting, so getting this done
sudo apt-get -qy install hadoop-conf-pseudo zookeeper-server 

#Everything else we'll have to install down. The installs aren't heavy, but the checkout and build are very heavy, so lets start them asap 
sudo apt-get -qy install make g++ g++-multilib; 
cd /tmp; 
wget --tries=0 --read-timeout=5 $apacheMirror/accumulo/1.4.2/accumulo-1.4.2-dist.tar.gz
tar -xzf accumulo-1.4.2-dist.tar.gz
cd /tmp/accumulo-1.4.2/src/server/src/main/c++/nativeMap
make

#hadoop via bigtop needs these dirs, but bigtop doesn't handle them. It does make the hdfs user/group which are necessary for them. So we do it after the fact
sudo mkdir -p /var/lib/hadoop/cache/hadoop/dfs/name /var/lib/hadoop/cache/hadoop/dfs/data
sudo chown -R hdfs:hdfs /var/lib/hadoop/cache/hadoop/dfs

#hadoop also needs to be formatted
echo Y | sudo -Eu hdfs /usr/lib/hadoop/bin/hadoop namenode -format

#Now that hadoop is functional, lets start everything
startPids=""
for hadoop in /etc/init.d/hadoop-*; do
  sudo $hadoop start &
  startPids="$startPids $!"
done

#Small tweak for zookeeper
sudo sed -e 's/maxClientCnxns=50/maxClientCnxns=100/' -i /etc/zookeeper/conf/zoo.cfg
sudo /etc/init.d/zookeeper-server restart &
zookeeperStart=$!

#And now lets put accumulo in a good directory
sudo mkdir /usr/lib/accumulo
sudo mv /tmp/accumulo-1.4.2/* /usr/lib/accumulo/

# Create our accumulo user and group
sudo mkdir -p /etc/default
echo "ACCUMULO_USER=accumulo\nACCUMULO_MONITOR_USER=accumulo_monitor\nACCUMULO_TRACER_USER=accumulo_tracer\nACCUMULO_LOG_DIR=/var/log/accumulo" | sudo tee /etc/default/accumulo
sudo useradd -Ud /usr/lib/accumulo accumulo
sudo useradd -d /usr/lib/accumulo -g accumulo accumulo_monitor
sudo useradd -d /usr/lib/accumulo -g accumulo accumulo_tracer

# Set up proper directories
sudo mkdir -p /var/log/accumulo
sudo mkdir -p /var/lib/accumulo/walogs
sudo mkdir -p /etc/accumulo/conf
sudo mv /usr/lib/accumulo/conf/* /etc/accumulo/conf
sudo rm -Rf /usr/lib/accumulo/conf /usr/lib/accumulo/logs
sudo ln -s /etc/accumulo/conf /usr/lib/accumulo/conf
sudo ln -s /var/lib/accumulo/walogs /usr/lib/accumulo/walogs
sudo ln -s /var/log/accumulo /usr/lib/accumulo/logs

# Get the configuration together
cd /usr/lib/accumulo/conf
maxMem=`free -g | grep Mem | awk '{print $2}'`
footprint=512MB
if [ "$maxMem" -ge "4" ]; then
  footprint=2GB
elif [ "$maxMem" -ge "3" ]; then
  footprint=1GB
fi

sudo cp -a examples/$footprint/native-standalone/* .

# Do our customization
sudo sed -i -e "s*/path/to/java*$JAVA_HOME*" -e 's*/path/to*/usr/lib*' accumulo-env.sh

# Set ownerships properly
sudo chown -R accumulo:accumulo /usr/lib/accumulo /var/log/accumulo /var/lib/accumulo /etc/accumulo/conf
sudo chmod 770 /var/lib/accumulo
sudo chmod -R 774 /var/log/accumulo /etc/accumulo/conf

#and wait for the hadoop processes to start
wait $startPids $zookeeperStart

# So now we can init accumulo
echo "accumulo\nsecret\nsecret" |  sudo -Eu accumulo /usr/lib/accumulo/bin/accumulo init

# And install the init.d scripts
cd /usr/lib/accumulo/src/assemble/platform/debian
sudo sh stand-alone-init.sh

# GREAT SUCCESS!
echo "System is now all set up and running. Enjoy"

