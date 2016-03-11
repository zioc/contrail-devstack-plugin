Devstack plugin for opencontrail
================================

This repo provides a devstack plugin to try and hack opencontrail + openstack.

Supported distros / relsases
============================

For now, ubuntu trusty (14.04) is the only supported distribution.

Requirements
============

As it'll be running openstack + opencontrail, the target system needs a
consequent amount of RAM. At least 6Gb are required to run all services.
8Gb and more will be more comfortable if you intent to run sime VMs.

Start a contrail cloud
======================

Install a fresh environment (with git), and pull devstack sources:

    git clone https://github.com/openstack-dev/devstack.git
    cd devstack

It may be safer to use a stable version of devstack & openstack

    git checkout stable/liberty

Copy sample local.conf into devstack directory, and enable this plugin

    cp samples/local.conf .

    echo "enable_plugin contrail https://github.com/zioc/contrail-devstack-plugin.git" >> local.conf

That's all, you can now launch devstack

    ./stack.sh

While the first run will probably take a couple of hours to fecth dependencies
and build contrail, subsequent runs of stack.sh should be mush faster!
