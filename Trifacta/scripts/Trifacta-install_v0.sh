#! /bin/bash
CORESITEPATH=/etc/hadoop/conf/core-site.xml
YARNSITEPATH=/etc/hadoop/conf/yarn-site.xml
AMBARICONFIGS_SH=/var/lib/ambari-server/resources/scripts/configs.sh
PORT=8080

WEBWASB_TARFILE=webwasb-tomcat.tar.gz
WEBWASB_TARFILEURI=https://hdiconfigactions.blob.core.windows.net/linuxhueconfigactionv01/$WEBWASB_TARFILE
WEBWASB_TMPFOLDER=/tmp/webwasb
WEBWASB_INSTALLFOLDER=/usr/share/webwasb-tomcat

ACTIVEAMBARIHOST=headnodehost

checkHostNameAndSetClusterName() {
    fullHostName=$(hostname -f)
    echo "fullHostName=$fullHostName"
    CLUSTERNAME=$(sed -n -e 's/.*\.\(.*\)-ssh.*/\1/p' <<< $fullHostName)
    if [ -z "$CLUSTERNAME" ]; then
        CLUSTERNAME=$(echo -e "import hdinsight_common.ClusterManifestParser as ClusterManifestParser\nprint ClusterManifestParser.parse_local_manifest().deployment.cluster_name" | python)
        if [ $? -ne 0 ]; then
            echo "[ERROR] Cannot determine cluster name. Exiting!"
            exit 133
        fi
    fi
    echo "Cluster Name=$CLUSTERNAME"
}

validateUsernameAndPassword() {
    coreSiteContent=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD get $ACTIVEAMBARIHOST $CLUSTERNAME core-site)
    if [[ $coreSiteContent == *"[ERROR]"* && $coreSiteContent == *"Bad credentials"* ]]; then
        echo "[ERROR] Username and password are invalid. Exiting!"
        exit 134
    fi
}

updateAmbariConfigs() {
    updateResult=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD set $ACTIVEAMBARIHOST $CLUSTERNAME core-site "hadoop.proxyuser.oozie.groups" "*")
    
    if [[ $updateResult != *"Tag:version"* ]] && [[ $updateResult == *"[ERROR]"* ]]; then
        echo "[ERROR] Failed to update core-site. Exiting!"
        echo $updateResult
        exit 135
    fi
    
    echo "Updated hadoop.proxyuser.hue.groups = *"
    
    updateResult=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD set $ACTIVEAMBARIHOST $CLUSTERNAME oozie-site "oozie.service.ProxyUserService.proxyuser.hue.hosts" "*")
    
    if [[ $updateResult != *"Tag:version"* ]] && [[ $updateResult == *"[ERROR]"* ]]; then
        echo "[ERROR] Failed to update oozie-site. Exiting!"
        echo $updateResult
        exit 135
    fi
    
    echo "Updated oozie.service.ProxyUserService.proxyuser.hue.hosts = *"
    
    updateResult=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD set $ACTIVEAMBARIHOST $CLUSTERNAME oozie-site "oozie.service.ProxyUserService.proxyuser.hue.groups" "*")
    
    if [[ $updateResult != *"Tag:version"* ]] && [[ $updateResult == *"[ERROR]"* ]]; then
        echo "[ERROR] Failed to update oozie-site. Exiting!"
        echo $updateResult
        exit 135
    fi
    
    echo "Updated oozie.service.ProxyUserService.proxyuser.hue.hosts = *"
}

stopServiceViaRest() {
    if [ -z "$1" ]; then
        echo "Need service name to stop service"
        exit 136
    fi
    SERVICENAME=$1
    echo "Stopping $SERVICENAME"
    curl -u $USERID:$PASSWD -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Stop Service for Hue installation"}, "Body": {"ServiceInfo": {"state": "INSTALLED"}}}' http://$ACTIVEAMBARIHOST:$PORT/api/v1/clusters/$CLUSTERNAME/services/$SERVICENAME
}

startServiceViaRest() {
    if [ -z "$1" ]; then
        echo "Need service name to start service"
        exit 136
    fi
    sleep 2
    SERVICENAME=$1
    echo "Starting $SERVICENAME"
    startResult=$(curl -u $USERID:$PASSWD -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Start Service for Hue installation"}, "Body": {"ServiceInfo": {"state": "STARTED"}}}' http://$ACTIVEAMBARIHOST:$PORT/api/v1/clusters/$CLUSTERNAME/services/$SERVICENAME)
    if [[ $startResult == *"500 Server Error"* || $startResult == *"internal system exception occurred"* ]]; then
        sleep 60
        echo "Retry starting $SERVICENAME"
        startResult=$(curl -u $USERID:$PASSWD -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Start Service for Hue installation"}, "Body": {"ServiceInfo": {"state": "STARTED"}}}' http://$ACTIVEAMBARIHOST:$PORT/api/v1/clusters/$CLUSTERNAME/services/$SERVICENAME)
    fi
    echo $startResult
}

downloadAndUnzipWebWasb() {
    echo "Removing WebWasb installation and tmp folder"
    rm -rf $WEBWASB_INSTALLFOLDER/
    rm -rf $WEBWASB_TMPFOLDER/
    mkdir $WEBWASB_TMPFOLDER/
    
    echo "Downloading webwasb tar file"
    wget $WEBWASB_TARFILEURI -P $WEBWASB_TMPFOLDER
    
    echo "Unzipping webwasb-tomcat"
    cd $WEBWASB_TMPFOLDER
    tar -zxvf $WEBWASB_TARFILE -C /usr/share/
    
    rm -rf $WEBWASB_TMPFOLDER/
}

setupWebWasbService() {
    echo "Adding webwasb user"
    useradd -r webwasb

    echo "Making webwasb a service and start it"
    sed -i "s|JAVAHOMEPLACEHOLDER|$JAVA_HOME|g" $WEBWASB_INSTALLFOLDER/upstart/webwasb.conf
    chown -R webwasb:webwasb $WEBWASB_INSTALLFOLDER

    cp -f $WEBWASB_INSTALLFOLDER/upstart/webwasb.conf /etc/init/
    initctl reload-configuration
    stop webwasb
    start webwasb
}

##############################
if [ "$(id -u)" != "0" ]; then
    echo "[ERROR] The script has to be run as root."
    usage
fi

USERID=$(echo -e "import hdinsight_common.Constants as Constants\nprint Constants.AMBARI_WATCHDOG_USERNAME" | python)

echo "USERID=$USERID"

PASSWD=$(echo -e "import hdinsight_common.ClusterManifestParser as ClusterManifestParser\nimport hdinsight_common.Constants as Constants\nimport base64\nbase64pwd = ClusterManifestParser.parse_local_manifest().ambari_users.usersmap[Constants.AMBARI_WATCHDOG_USERNAME].password\nprint base64.b64decode(base64pwd)" | python)

export JAVA_HOME=/usr/lib/jvm/java-7-openjdk-amd64

if [ -e $HUE_INSTALLFOLDER ]; then
    echo "Hue is already installed. Exiting ..."
    exit 0
fi

echo JAVA_HOME=$JAVA_HOME

checkHostNameAndSetClusterName
validateUsernameAndPassword
updateAmbariConfigs
stopServiceViaRest HDFS
stopServiceViaRest YARN
stopServiceViaRest MAPREDUCE2
stopServiceViaRest OOZIE

echo "Download and unzip WebWasb while services are STOPPING"
downloadAndUnzipWebWasb

startServiceViaRest YARN
startServiceViaRest MAPREDUCE2
startServiceViaRest OOZIE
startServiceViaRest HDFS

setupWebWasbService
