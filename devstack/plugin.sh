#!/bin/bash

function fetch_contrail() {
    if ! which repo > /dev/null 2>&1 ; then
        wget http://commondatastorage.googleapis.com/git-repo-downloads/repo
        chmod 0755 repo
        sudo mv repo /usr/bin
    fi

    if [[ ! -d "$CONTRAIL_DEST/.repo"  || "$RECLONE" = "True" ]]; then
        sudo mkdir -p $CONTRAIL_DEST
        safe_chown -R $STACK_USER $CONTRAIL_DEST
        safe_chmod 0755 $CONTRAIL_DEST
        cd "$CONTRAIL_DEST"
        repo init -u "$CONTRAIL_REPO" -b "$CONTRAIL_BRANCH"
        sed -i 's/\.\./\./' .repo/manifest.xml
        repo sync
        cd "$TOP_DIR"

        # Apply extra patches if needed
        if [[ -n "$CONTRAIL_PATCHES" ]]; then
            if [[ -f "$CONTRAIL_PATCHES" ]]; then
                source $CONTRAIL_PATCHES
            else
                eval $CONTRAIL_PATCHES
            fi
        fi
        cd "$TOP_DIR"
    fi

    if [[ ! -e "$CONTRAIL_DEST/third_party/FETCH_DONE" || "$RECLONE" = "True" ]]; then
        python $CONTRAIL_DEST/third_party/fetch_packages.py && touch "$CONTRAIL_DEST/third_party/FETCH_DONE"
    fi
}

function install_cassandra() {
    if ! which cassandra > /dev/null 2>&1 ; then
        echo "Installing cassanadra"
        echo "deb http://www.apache.org/dist/cassandra/debian 21x main" | \
        sudo tee /etc/apt/sources.list.d/cassandra.list
        # Use curl instead of gpg as it deals better with proxies
        curl -sL --retry 5 "http://pgp.mit.edu/pks/lookup?op=get&search=0x749D6EEC0353B12C" | sudo apt-key add -

        sudo -E apt-get update
        sudo -E apt-get install -y cassandra
    fi
}

function install_cassandra_cpp_driver() {
    if ! ldconfig -p |grep -q libcassandra ; then
        echo "Installing cassanadra CPP drivers"
        TMP_PKG_DIR=$(mktemp -d)
        cd $TMP_PKG_DIR
        wget http://downloads.datastax.com/cpp-driver/ubuntu/14.04/cassandra/v2.2.2/cassandra-cpp-driver_2.2.2-1_amd64.deb
        wget http://downloads.datastax.com/cpp-driver/ubuntu/14.04/cassandra/v2.2.2/cassandra-cpp-driver-dev_2.2.2-1_amd64.deb
        wget http://downloads.datastax.com/cpp-driver/ubuntu/14.04/dependencies/libuv/v1.7.5/libuv_1.7.5-1_amd64.deb

        sudo dpkg -i *.deb

        cd $TOP_DIR
        rm -Rf $TMP_PKG_DIR
    fi
}

function fetch_webui(){
    if [[ ! -e "$CONTRAIL_DEST/contrail-webui-third-party/FETCH_DONE" || "$RECLONE" == "True" ]]; then
        cd $CONTRAIL_DEST/contrail-web-core
        sed -ie "s|webController\.path.*|webController\.path = \'$CONTRAIL_DEST/contrail-web-controller\';|" config/config.global.js
        make fetch-pkgs-prod
        make dev-env REPO=webController
        touch $CONTRAIL_DEST/contrail-webui-third-party/FETCH_DONE
        cd $TOP_DIR
    fi
}

function insert_vrouter() {

    if ! lsmod | grep -q vrouter; then
        echo_summary "Inserting vrouter kernel module"
        sudo insmod $CONTRAIL_DEST/vrouter/vrouter.ko $VR_KMOD_OPTS
        if [[ ! $? -eq 0 ]]; then
            echo_summary "Failed to insert vrouter kernel module"
            return 1
        fi
    fi

    #Check if vrouter interface have already been added
    if ip link show |grep -q vhost0; then
        return 0
    fi

    DEV_MAC=$(cat /sys/class/net/$VHOST_INTERFACE_NAME/address)

    sudo vif --create vhost0 --mac $DEV_MAC
    sudo vif --add $VHOST_INTERFACE_NAME --mac $DEV_MAC --vrf 0 --vhost-phys --type physical
    sudo vif --add vhost0 $DEVICE --mac $DEV_MAC --vrf 0 --xconnect $VHOST_INTERFACE_NAME --type vhost

    sudo ip link set vhost0 up
    sudo ip addr add $VHOST_INTERFACE_CIDR dev vhost0
    # Migrate routes to vhost0
    sudo ip route show dev $VHOST_INTERFACE_NAME scope global | while read route; do
        sudo ip route replace $route dev vhost0 || true
    done
    sudo ip addr flush dev $VHOST_INTERFACE_NAME
}

function remove_vrouter() {

    ! lsmod | grep -q vrouter && return 0

    echo_summary "Removing vrouter kernel module"

    sudo ip addr add $VHOST_INTERFACE_CIDR dev $VHOST_INTERFACE_NAME || true #dhclient may have already done that
    sudo ip route show dev vhost0 scope global | while read route; do
    # Migrate routes back to physical interface
        sudo ip route replace $route dev $VHOST_INTERFACE_NAME || true
    done
    sudo ip addr flush dev vhost0

    sudo vif --list | awk '$1~/^vif/ {print $1}' |  sed 's|.*/||' | xargs -I % sudo vif --delete %
    #NOTE: as it is executed in stack.sh, vrouter-agent shoudn't be running, we should be able to remove vrouter module
    sudo rmmod vrouter
}

function start_contrail() {
    # Start contrail in an independant screen
    STACK_SCREEN_NAME="$SCREEN_NAME"
    SCREEN_NAME=$CONTRAIL_SCREEN_NAME

    USE_SCREEN=$(trueorfalse True USE_SCREEN)
    if [[ "$USE_SCREEN" == "True" ]]; then
        # Create a new named screen to run processes in
        screen -d -m -S $SCREEN_NAME -t shell -s /bin/bash
        sleep 1

        # Set a reasonable status bar
        SCREEN_HARDSTATUS=${SCREEN_HARDSTATUS:-}
        if [ -z "$SCREEN_HARDSTATUS" ]; then
            SCREEN_HARDSTATUS='%{= .} %-Lw%{= .}%> %n%f %t*%{= .}%+Lw%< %-=%{g}(%{d}%H/%l%{g})'
        fi
        screen -r $SCREEN_NAME -X hardstatus alwayslastline "$SCREEN_HARDSTATUS"
        screen -r $SCREEN_NAME -X setenv PROMPT_COMMAND /bin/true
    fi

    # Clear ``screenrc`` file
    SCREENRC=$TOP_DIR/$SCREEN_NAME-screenrc
    if [[ -e $SCREENRC ]]; then
        rm -f $SCREENRC
    fi

    # Initialize the directory for service status check
    init_service_check

    # Ensure log directory will be writable
    #chown $STACK_USER:$STACK_USER /var/log/contrail
    sudo chmod 777 /var/log/contrail

    run_process vrouter "sudo contrail-vrouter-agent --config_file=/etc/contrail/contrail-vrouter-agent.conf"
    run_process api-srv "contrail-api --conf_file /etc/contrail/contrail-api.conf"
    # Wait for api to be ready, as it creates cassandra CF required for disco to start
    is_service_enabled api-srv && wget --no-proxy --retry-connrefused --no-check-certificate --waitretry=1 -t 60 -q -O /dev/null http://$APISERVER_IP:8082 || true
    run_process disco "contrail-discovery --conf_file /etc/contrail/contrail-discovery.conf"
    run_process svc-mon "contrail-svc-monitor --conf_file /etc/contrail/contrail-svc-monitor.conf"
    run_process schema "contrail-schema --conf_file /etc/contrail/contrail-schema.conf"
    run_process control "sudo contrail-control --conf_file /etc/contrail/contrail-control.conf"
    run_process collector "contrail-collector --conf_file /etc/contrail/contrail-collector.conf"
    run_process analytic-api "contrail-analytics-api --conf_file /etc/contrail/contrail-analytics-api.conf"
    run_process query-engine "contrail-query-engine --conf_file /etc/contrail/contrail-query-engine.conf"
    run_process dns "contrail-dns --conf_file /etc/contrail/dns/contrail-dns.conf"
    #NOTE: contrail-dns checks for '/usr/bin/contrail-named' in /proc/[pid]/cmdline to retrieve bind status
    run_process named "sudo /usr/bin/contrail-named -g -c /etc/contrail/dns/contrail-named.conf"

    run_process ui-jobs "cd $CONTRAIL_DEST/contrail-web-core; sudo nodejs jobServerStart.js"
    run_process ui-webs "cd $CONTRAIL_DEST/contrail-web-core; sudo nodejs webServerStart.js"

    SCREEN_NAME="$STACK_SCREEN_NAME"
}

if [[ "$1" == "stack" && "$2" == "source" ]]; then
    # Called after projects lib are sourced, before packages installation

    # Check to see if we are already running DevStack
    # Note that this may fail if USE_SCREEN=False
    if type -p screen > /dev/null && screen -ls | egrep -q "[0-9]\.$CONTRAIL_SCREEN_NAME"; then
        echo "You are already running a stack.sh session."
        echo "To rejoin this session type 'screen -x stack'."
        echo "To destroy this session, type './unstack.sh'."
        exit 1
    fi

    # opencontrail ppa repo must be enabled in "source" phase, which happens before
    # package installation. This way, ppa packages in files/debs will be installable.
    if ! which add-apt-repository > /dev/null 2>&1 ; then
        sudo -E apt-get update
        sudo -E apt-get -y install python-software-properties
    fi
    if ! apt-cache policy | grep -q opencontrail; then
        sudo -E add-apt-repository -y ppa:opencontrail
        # pin ppa packages priority to prevent conflicts, only packages not found elsewhere will be installed from this ppa
        cat <<- EOF | sudo tee /etc/apt/preferences.d/contrail-ppa
			Package: librdkafka*
			Pin: release l=OpenContrail
			Pin-Priority: 990

			Package: *
			Pin: release l=OpenContrail
			Pin-Priority: 50
		EOF
    fi

    #FIXME: workaround ifmap-server package issue (doesn't creates /etc/contrail but needs it to start)
    sudo mkdir -p /etc/contrail

elif [[ "$1" == "stack" && "$2" == "pre-install" ]]; then
    # Called afer pip requirements installation

    fetch_contrail

    if is_service_enabled api-srv disco svc-mon schema control collector analytic-api query-engine dns named; then
        install_cassandra
        install_cassandra_cpp_driver

        # Packages should have been installed by devstack
        #install_package $(_parse_package_files $CONTRAIL_DEST)

        echo_summary "Building contrail"
        cd $CONTRAIL_DEST
        sudo -E scons $SCONS_ARGS
        cd $TOP_DIR

        # As contrail's python packages requirements aren't installed
        # automatically, we have to manage their installation.
        pip_install -r $CONTRAIL_PLUGIN_DIR/files/requirements.txt

    fi
    if is_service_enabled vrouter; then
        echo_summary "Building contrail vrouter"

        cd $CONTRAIL_DEST

        # Build vrouter-agent if not done earlier
        if ! is_service_enabled api-srv disco svc-mon schema control collector analytic-api query-engine dns named; then
            sudo -E scons $SCONS_ARGS controller/src/vnsw
        fi

        # Build vrouter kernel module
        sudo -E scons $SCONS_ARGS ./vrouter

        pip_install -r controller/src/vnsw/opencontrail-vrouter-netns/requirements.txt
        if _vercmp $CONTRAIL_BRANCH "<=" R3.1; then
            pip_install -r controller/src/vnsw/contrail-vrouter-api/requirements.txt
        fi

        cd $TOP_DIR
    fi
    if is_service_enabled ui-webs ui-jobs; then
        # Fetch 3rd party and install webui
        fetch_webui
    fi

elif [[ "$1" == "stack" && "$2" == "install" ]]; then
    # Called after services installation

    if is_service_enabled q-svc; then
        # Build contrail neutron plugin as it isn't handled by scons
        # It should happen after neutron installation, as it depends on neutron
        #FIXME? as contrail neutron plugin misses a setup.cfg, we wan't use setup_develop
        setup_package $CONTRAIL_DEST/openstack/neutron_plugin -e
    fi

    echo_summary "Configuring contrail"

    source $CONTRAIL_PLUGIN_DIR/lib/contrail_config
    # Use bash completion features to conveniently run all config functions
    for config_func in $(compgen -A function contrail_config_); do
        eval $config_func
    done

    # Force vrouter module re-insertion if asked
    [[ "$RELOAD_VROUTER" == "True" ]] && remove_vrouter
    insert_vrouter

elif [[ "$1" == "stack" && "$2" == "post-config" ]]; then
    # Called after services configuration

    echo_summary "Starting contrail"
    #FIXME: Contrail api must be started before neutron, this is why it must be done here.
    # But shouldn't neutron plugin reconnect if api is unreacheable?
    start_contrail

    echo_summary "Provisionning contrail"

    local provision_api_args="--api_server_ip $SERVICE_HOST --api_server_port 8082 \
        --admin_user $CONTRAIL_ADMIN_USER --admin_password $CONTRAIL_ADMIN_PASSWORD --admin_tenant_name $CONTRAIL_ADMIN_PROJECT"

    if is_service_enabled vrouter ; then
        /usr/share/contrail/provision_vrouter.py $provision_api_args \
            --oper add --host_name $CONTRAIL_HOSTNAME --host_ip $VHOST_INTERFACE_IP \
            || /bin/true    # Failure is not critical
    fi
    if is_service_enabled control ; then
        /usr/share/contrail/provision_control.py $provision_api_args \
            --oper add --host_name $CONTRAIL_HOSTNAME --host_ip $CONTROL_IP --router_asn 64512 \
            || /bin/true    # Failure is not critical
    fi
    if is_service_enabled api-srv ; then
        /usr/share/contrail/provision_linklocal.py $provision_api_args \
            --oper add --linklocal_service_name metadata --linklocal_service_ip 169.254.169.254 \
            --linklocal_service_port 80 --ipfabric_service_ip $NOVA_SERVICE_HOST --ipfabric_service_port 8775 \
            || /bin/true    # Failure is not critical
    fi
    if [[ "$Q_L3_ENABLED" == "True" ]]; then
        sudo /usr/share/contrail/provision_vgw_interface.py --oper create \
            --interface vgw --subnets $FLOATING_RANGE --routes 0.0.0.0/0 \
            --vrf "default-domain:admin:$PUBLIC_NETWORK_NAME:$PUBLIC_NETWORK_NAME"
        if [[ "$VGW_MASQUERADE" == "True" ]] && ! sudo iptables -t nat -C POSTROUTING -s $FLOATING_RANGE -j MASQUERADE > /dev/null 2>&1; then
            sudo iptables -t nat -A POSTROUTING -s $FLOATING_RANGE -j MASQUERADE
        fi
    fi

elif [[ "$1" == "stack" && "$2" == "extra" ]]; then
    # Called after services provisionning (images, default networks...)
    :

elif [[ "$1" == "unstack" ]]; then
    # Clean up the remainder of the screen processes
    SCREEN=$(which screen)
    if [[ -n "$SCREEN" ]]; then
        SESSION=$(screen -ls | awk "/[0-9]+.${CONTRAIL_SCREEN_NAME}/"'{ print $1 }')
        if [[ -n "$SESSION" ]]; then
            screen -X -S $SESSION quit
        fi
    fi

elif [[ "$1" == "clean" ]]; then
    #no-op
    :
fi
