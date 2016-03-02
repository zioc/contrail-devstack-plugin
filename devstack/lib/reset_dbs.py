#!/usr/bin/python

import argparse
import time

from kazoo.client import KazooClient
from pycassa.system_manager import SystemManager
from thrift.transport.TTransport import TTransportException
from vnc_api.vnc_api import *

def conn_retry(func):
    def wrapper(*args, **kwargs):
        for i in range(10):
            try:
                func(*args, **kwargs)
            except Exception as e:
                time.sleep(5)
                print 'Exception while trying to connect: %s'  % e
                continue
            break

    return wrapper

@conn_retry
def clean_zookeeper(zk_ips):
    zk_hosts = ['%s:2181' % zk_ip for zk_ip in zk_ips.split(',')]
    zk_client = KazooClient(hosts=','.join(zk_hosts))
    zk_client.start()

    children = zk_client.get_children('/')
    print("Zookeeper childrens: %s" % children)

    for child in children:
        if child != 'zookeeper':
            zk_client.delete(child, recursive=True)

    print("Remaining Zookeeper childrens: %s" % zk_client.get_children('/'))
    zk_client.stop()

@conn_retry
def clean_cassandra(cass_ip):
    sys_mgr = SystemManager('%s:9160' % cass_ip)

    keyspaces_list = sys_mgr.list_keyspaces()
    print("Cassandra keyspaces: %s" % keyspaces_list)

    for keyspace in ['to_bgp_keyspace', 'DISCOVERY_SERVER',
                     'useragent', 'svc_monitor_keyspace',
                     'config_db_uuid', 'ContrailAnalyticsCql' ]:
        try:
            sys_mgr.drop_keyspace(keyspace)
        except Exception as e:
            print("Error: %s" % e)

    print("Remaining Cassandra keyspaces: %s" % sys_mgr.list_keyspaces())

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zookeeper_ips", default='127.0.0.1')
    parser.add_argument("--cassandra_ip", default='127.0.0.1')
    args = parser.parse_args()

    clean_zookeeper(args.zookeeper_ips)
    clean_cassandra(args.cassandra_ip)

if __name__ == '__main__':
    main()
