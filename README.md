Devstack plugin for opencontrail
================================

This repo provides a devstack plugin to try and hack opencontrail + openstack.

Supported distros / releases
============================

For now, ubuntu trusty (14.04) is the only supported distribution.

Requirements
============

As it'll be running openstack + opencontrail, the target system needs at least
6Gb RAM and 20 Gb disk to run all services.

8Gb RAM and more will be more comfortable if you intend to run some VMs.

Start a contrail cloud
======================

Install a fresh environment (with git), and pull devstack sources:

    git clone https://github.com/openstack-dev/devstack.git
    cd devstack

It may be safer to use a stable version of devstack & openstack

    git checkout stable/mitaka

Copy sample local.conf into devstack directory, and enable this plugin

    cp samples/local.conf .
    echo "enable_plugin contrail https://github.com/zioc/contrail-devstack-plugin.git" >> local.conf

That's all, you can now launch devstack

    ./stack.sh

While the first run will probably take a couple of hours to fetch dependencies
and build contrail, subsequent runs of stack.sh should be mush faster!

Custom parameters
=================

All parameters related to this plugin are defined in devstack/settings,
they may be overwritten in your local.conf, for example:

    #Use R3.0 contrail branch
    CONTRAIL_BRANCH=R3.0

    #Provide a custom list of enabled services (by default dns and webui would be enabled in addition to the following list)
    enable_service vrouter api-srv disco svc-mon schema control collector analytics-api query-engine
