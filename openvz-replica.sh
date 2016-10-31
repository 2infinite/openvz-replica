#!/bin/sh

# Setup key at node:
# cat .ssh/id_rsa.pub | ssh root@node 'cat >> .ssh/authorized_keys ; chmod 600 .ssh/authorized_keys; chmod 700 .ssh'

### Settings:
# Openvz nodes:
NODES="node1.local node2.local"
# Openvz Containers for backup
CTS="1111 2222"


# Number of snapshots
MAXSNAPS=7
# Number backups for *.conf for openvz containers
MAXSCONF=7

# Define rsync params
RSYNC="rsync -va -e ssh  --delete"

PIDFILE="/var/run/`basename $0`.pid"
LOGFILE="/var/log/`basename $0`.log"

# Maximum log size in MB
MAXLOGSIZE=100

# REQUIED free space on /vz in GB
VZFREE=30


export LC_ALL=C
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/root/bin


checkerr()
{
if [ $1 -ne 0 ];
then
echo "`date` Error: $@" >> ${LOGFILE}
echo "`date` Error: $@"
fi
}

log()
{
echo "==> `date` $@" >> ${LOGFILE}
}

checkpid()
{
if [ -f "${PIDFILE}" ]; then
pgrep -P  `cat ${PIDFILE}`
	if [ $? -eq 0 ]; then
	echo $0 already running with pid=`cat ${PIDFILE}`
	exit
	else
	echo $$ > ${PIDFILE}
	fi
else
	echo $$ > ${PIDFILE}
fi
}


getveid()
{
TARGETNODE=$1
ALLVEID=""
CTS4NODE=""
ALLVEID=`ssh $TARGETNODE "vzlist -H -o veid | xargs"`
checkerr $? ssh $TARGETNODE "vzlist -H -o veid | xargs"
log "== For $TARGETNODE available containers is ALLVEID=$ALLVEID"
for ct in ${CTS}
do
echo ${ALLVEID} | grep -qw $ct
if [ $? -eq 0 ]; then
CTS4NODE="`echo ${CTS4NODE} $ct`"
fi
done
log "== For $TARGETNODE will be backuped is CTS4NODE=$CTS4NODE"
}

deletesnaps()
{
FIRSTSNAP="`vzctl snapshot-list  $newctid -H -o UUID | head -n 1`"
log "== Delete snapshot on $node for CTID=$ctid --id ${FIRSTSNAP}:" 
ssh $node "vzctl snapshot-delete $ctid --id ${FIRSTSNAP}" >> ${LOGFILE} 
ERR=$?
checkerr $ERR ssh $node "vzctl snapshot-delete $ctid --id ${FIRSTSNAP}" 
if [ $ERR -eq 0 ];then
	log "== Delete snapshot on `hostname` for CTID=$newctid --id ${FIRSTSNAP}:"
	vzctl snapshot-delete $newctid --id ${FIRSTSNAP} >> ${LOGFILE}
	checkerr $? vzctl snapshot-delete $newctid --id ${FIRSTSNAP}
fi
}

rotatelog()
{
if [ -f ${LOGFILE} ]; then
	LOGSIZE=`du -m ${LOGFILE} | awk '{print $1}'`
	if [ ${LOGSIZE} -gt ${MAXLOGSIZE} ]; then 
	 log "Rotate log"
	 mv ${LOGFILE} ${LOGFILE}.1
	if [ -f ${LOGFILE}.1.bz2 ]; then
	 mv ${LOGFILE}.1.bz2 ${LOGFILE}.2.bz2
	fi
	bzip2 ${LOGFILE}.1
	fi
fi
}


####################################################################################################################################
# main

checkpid
rotatelog
log "=============================================================================================================================="
log "========= Start with pid $$"

for node in $NODES
do
	getveid $node
	if [ -n "${CTS4NODE}" ];then
		for ctid in ${CTS4NODE}
		do
# Make rsync to newctid:
		newctid=`expr 1000000 + $ctid`

# Check for running newctid:
		 log "== Check for running newctid:" 
	 	 vzlist -H -o veid 2>>${LOGFILE} | grep -qw ${newctid} 
	 	 if [ $? -eq 0 ]; then
	   		echo "`date` Abort Cloning $ctid  to RUNNING ${newctid}"
 	   		log "Abort Cloning $ctid  to RUNNING ${newctid}" 
	 else
		log "=== Cloning from $node CTID=$ctid to BACKUPCTID=$newctid:" 

# Check for Available space on /vz              
                VZSIZE=$( ssh $node "df --direct --block-size=1G /vz" | grep -v Available | awk '{print $4}' )
                log "== Check for Available space on /vz: size=${VZSIZE}GB"
                if [ ${VZSIZE} -lt ${VZFREE} ]; then
                        checkerr 1 NO available space on /vz, ABORT BACKUP for CTID=${ctid}: on $node VZSIZE=${VZSIZE}
           continue
                fi

# Make root dir for CT
                mkdir -p  /vz/root/${newctid}/root.hdd
		mkdir -p  /vz/private/${newctid}/root.hdd
                chmod 700 /vz/private/${newctid}/root.hdd

# Make canary file:
                CHECKSTRING="`date` `uuidgen`"
                echo "${CHECKSTRING}" | ssh ${node} "cat > /vz/root/\"${ctid}\"/var/tmp/checkfile"

# Snapshot CT

                log "== Snapshot CTID=$ctid on $node:"
                ssh $node "vzctl snapshot ${ctid} --skip-suspend --skip-config" >> ${LOGFILE}
                checkerr $? ssh $node "vzctl snapshot ${ctid} --skip-suspend --skip-config"

# Check size of root.hdd
                if [ -s "/vz/private/${newctid}/root.hdd/root.hdd" ]; then
                SIZEHDD=`ssh $node "ls -l /vz/private/${ctid}/root.hdd/root.hdd" | awk '{print $5}'`
                NEWSIZEHDD=`ls -l /vz/private/${newctid}/root.hdd/root.hdd | awk '{print $5}'`
                        if [ ${SIZEHDD} -ne ${NEWSIZEHDD} ]; then
                                checkerr 1 Sizes of root.hdd are different, ABORT BACKUP for CTID=${ctid}: on $node root.hdd=${SIZEHDD}, on `hostname` root.hdd=${NEWSIZEHDD}
				continue
                        fi
                else
                checkerr 1 File /vz/private/${newctid}/root.hdd/root.hdd is not exist or has a zero size, will make FULL BACKUP:
# Rsync private root.hdd
                log "== Rsync private root.hdd: ${RSYNC} $node:/vz/private/${ctid}/root.hdd/root.hdd /vz/private/${newctid}/root.hdd/"
                ${RSYNC} $node:/vz/private/${ctid}/root.hdd/root.hdd /vz/private/${newctid}/root.hdd/ >> ${LOGFILE}
                checkerr $? ${RSYNC} $node:/vz/private/${ctid}/root.hdd/root.hdd /vz/private/${newctid}/root.hdd/
                fi

# Rsync config
		log "== Rsync config: ${RSYNC} $node:"/etc/vz/conf/${ctid}.conf" /var/tmp/:"
		${RSYNC} $node:"/etc/vz/conf/${ctid}.conf" /var/tmp/ >> ${LOGFILE}
		checkerr $? ${RSYNC} $node:"/etc/vz/conf/${ctid}.conf" /var/tmp/
# Rotate conf
		n=${MAXSCONF}
		while [ $n -ge 1 ]
 		  do
		    if [ -f /etc/vz/conf/${newctid}.conf.`expr $n - 1`.back ]; then
		    mv -f /etc/vz/conf/${newctid}.conf.`expr $n - 1`.back /etc/vz/conf/${newctid}.conf.$n.back
		    fi
		    n=`expr $n - 1`
		done
		if [ -f /etc/vz/conf/${newctid}.conf ]; then
			mv /etc/vz/conf/${newctid}.conf /etc/vz/conf/${newctid}.conf.1.back
		fi
		mv /var/tmp/${ctid}.conf /etc/vz/conf/${newctid}.conf

# Fix paths in conf
                sed -i 's/VE_ROOT=.*$/VE_ROOT="\/vz\/root\/$VEID"/g' /etc/vz/conf/${newctid}.conf
                sed -i 's/VE_PRIVATE=.*$/VE_PRIVATE="\/vz\/private\/$VEID"/g' /etc/vz/conf/${newctid}.conf
# Disable USB in conf (for check backup without errors) 
		sed -i 's/^DEVNODES=/#DEVNODES=/g' /etc/vz/conf/${newctid}.conf
		
# Disable auto start backuped container during system boot:
                log "== Disable auto start CT=$newctid:" 
                vzctl set $newctid --save --onboot no >> ${LOGFILE}
                checkerr $? vzctl set $newctid --save --onboot no >> ${LOGFILE}

# Rsync private root.hdd.*
		log "== Rsync private root.hdd.*: ${RSYNC} $node:/vz/private/${ctid}/root.hdd/root.hdd.* /vz/private/${newctid}/root.hdd/"
		${RSYNC} $node:/vz/private/${ctid}/root.hdd/root.hdd.* /vz/private/${newctid}/root.hdd/ >> ${LOGFILE}
		ERR=$?
		checkerr $ERR ${RSYNC} $node:/vz/private/${ctid}/root.hdd/root.hdd.* /vz/private/${newctid}/root.hdd/
		log  "== Finish cloning root.hdd.* from $node CTID=$ctid to BACKUPCTID=$newctid with rsync return code=$ERR" 

		if [ $ERR -eq 0 ]
		then
# Rsync private DiskDescriptor*
		log "== Rsync DiskDescriptor*: ${RSYNC} $node:/vz/private/${ctid}/root.hdd/DiskDescriptor* /vz/private/${newctid}/root.hdd/"
		${RSYNC} $node:/vz/private/${ctid}/root.hdd/DiskDescriptor* /vz/private/${newctid}/root.hdd/ >> ${LOGFILE}
		checkerr $? $node:/vz/private/${ctid}/root.hdd/DiskDescriptor* /vz/private/${newctid}/root.hdd/
# Rsync private Snapshots*
		log "== Rsync Snapshots*: ${RSYNC} $node:/vz/private/${ctid}/Snapshots* /vz/private/${newctid}/" 
		${RSYNC} $node:/vz/private/${ctid}/Snapshots* /vz/private/${newctid}/ >> ${LOGFILE}
		checkerr $? {RSYNC} $node:/vz/private/${ctid}/Snapshots* /vz/private/${newctid}/
# Switch to Last Snapshot:		
		LASTSNAP="`vzctl snapshot-list  $newctid -H -o UUID | tail -n 1`"
                log  "== Switch to Last Snapshot=${LASTSNAP}"
                ploop snapshot-switch -u ${LASTSNAP} /vz/private/${newctid}/root.hdd/DiskDescriptor.xml >> ${LOGFILE}
                checkerr $? ploop snapshot-switch -u ${LASTSNAP} /vz/private/${newctid}/root.hdd/DiskDescriptor.xml

# Delete snapshotis:
		NUMSNAPS=`vzctl snapshot-list $newctid -H -o UUID | wc -l`
		while [ ${NUMSNAPS} -gt ${MAXSNAPS} ]
			do
			deletesnaps
			NUMSNAPS=`expr ${NUMSNAPS} - 1`
		done

# rpm --verify:
		ploop mount -m /vz/root/${newctid} /vz/private/${newctid}/root.hdd/DiskDescriptor.xml >> ${LOGFILE} 
		checkerr $? mount -m /vz/root/${newctid} /vz/private/${newctid}/root.hdd/DiskDescriptor.xml
		cat /vz/root/${newctid}/etc/issue | grep -q CentOS
		OS=$?
		if [ $OS -eq 0 ]
		then
		 log  "== Begin rpm --verify in /vz/root/${newctid}:"
		 RPMOUT=`chroot "/vz/root/${newctid}" rpm -Va | egrep -v \("/etc/"\|"/root"\|".M.......    /"\|"/dev/"\|"/var/"\|"/run/"\)`
			if [ -n "${RPMOUT}" ];then
				checkerr 1 Errors in BACKUPCT=${newctid} rpm --verify: `echo ${RPMOUT}`
			fi
		fi

# verify CHECKSTRING:
		log  "== Begin verify CHECKSTRING in /vz/root/${newctid}/var/tmp/checkfile"		
		cat /vz/root/${newctid}/var/tmp/checkfile | grep -qw "${CHECKSTRING}"
		checkerr $? Error in BACKUPCT=${newctid}: CHECKSTRING="${CHECKSTRING}" failed
# umount ploop
                log  "== vzctl umount ${newctid}"
                vzctl umount ${newctid} >> ${LOGFILE}
                checkerr $? vzctl umount ${newctid}
		log  "=== Finish Cloning from $node CTID=$ctid to BACKUPCTID=$newctid:"
# Remove old snapshots
			if [ -d "/vz/private/${newctid}/root.hdd/" ]; then
				MAXSNAPS2=`expr ${MAXSNAPS} \* 2`
				log  "== Remove old snapshots: find /vz/private/${newctid}/root.hdd/ -type f -name  "root.hdd.{*" -mtime +$MAXSNAPS2  -exec rm {} \+"
				find /vz/private/${newctid}/root.hdd/ -type f -name  "root.hdd.{*" -mtime +${MAXSNAPS2}  -exec rm {} \+
			fi
		fi
	  fi
		done
	fi
done

log "========= End with pid $$" 
rm "${PIDFILE}"
#EOF
