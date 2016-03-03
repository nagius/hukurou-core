Hukurou Core
============

Hukurou, Another monitoring tool, the modern way.

This software is the core component (API and Database) of the Hukurou monitoning system.

Why another monitoring tool ?
=============================

Because [#MonitoringSucks](https://github.com/monitoringsucks).

We spend a lots of time testing and comparing all Open Source monitoring tools (Xymon, Nagios, CheckMK, Icinga, Shinken, Centreon, Zenoss, Zabbix, Sensu ...). And despite they all have some interesting qualities, none of them was good enough to make the difference.

Sensu is the most interesting one, but it lack some mandatory features like remote checks (blackbox monitoring). And the global mindset is slightly different from what we were looking at. Nevertheless, some concept and component of Hukurou are inpired by Sensu (including the Japanese name).

So we decided it was time to build our own tool, the best one in regard of our 15 years of experience supporting production systems. One (more) tool to rule them all.


Hukurou is designed for big scale. The initial specs was a minimum of 10k devices. I dont known if we will succeed, but at least we're [trying to do something](http://obfuscurity.com/2011/07/Monitoring-Sucks-Do-Something-About-It) we love working with.


Key features :
==============

The purpose of this tool is to achieve monitoring with these goal in mind :

- Masterless architecture
- Simple scalability without limits
- Configuration on plain text file easily human-editable and parsable (YAML)
- No graphing : only alerting (but with links to a graphing system from GUI)
- No anomaly detection : that the job of the graphing tool
- Multi datacenter Dashboard
- Tree view of the inventory
- No concept of 'template' but inheritance of configuration within the tree
- Reload hosts/inventory configuration without restarting the application
- Auto-classify devices in the tree using regex
- Auto-configuration of the agent, configuration centralized on the core
- No need of autodiscovery: monitoring must be pro-active, not accidental
- Use REST call with Load Balancer as much as possible for communication between components
- Feeding :
    - Do pooling with active and passive check (whitebox and blackbox monitoring)
    - No SSH checks ! This is ugly and performance impacting
    - Compatible with Nagios and Sensu check_* scripts

- Try to follow UNIX philosophy :
    - Do only one thing, but do it well
    - Everything is file


Architecture
============


```
                                       +---------+
                                       |         |
 +---------+                           |  Core   |
 |         |                     +---> |         +-----+
 |  GUI    |                     |     |         |     |                     +--------------+
 |         +-----+               |     +---------+     |   +---------+       |              |
 |         |     |               |                     |   |         |       |  Escalation  |
 +---------+     |               |                     +---+         +-------+  module      |
                 |    +----+     |     +---------+         |         |       |              |
                 |    |    |     |     |         |         |  Redis  |       +--------------+
                 +--> | LB +-----+     |  Core   |         |         |
                      |HTTP|---------> |         +---------+         |
                 +--> |    +-----+     |         |         |         |
 +---------+     |    +----+     |     +---------+         |         |
 |         |     |               |                     +---+         |       +---------------+
 |  Agent  |     |               |                     |   |         +-------+               |
 |         +-----+               |     +---------+     |   +---------+       |  Correlation  |
 |         |                     |     |         |     |                     |  engine       |
 +---------+                     |     |  Core   +-----+                     |               |
                                 +---> |         |                           +---------------+
                                       |         |
                                       +---------+
```

For now, only the Core and the Agent exists. Redis is a regular instance of the database. LB can be any type of HTTP load-balancer.
The other components (GUI, Escalation, Correlation) are on the todo list.


Configuration
=============

Core configuration
------------------

File /etc/hukurou/core/config.yml

See config/config.example.yml


Services configuration
----------------------

All service's checks must be declared in the file /etc/hukurou/core/services.yml with their default configuration :

```
---
fping:                          # Service name
    remote: true                # Remote check, will be executed by the core
    disabled: false				# Will not be disabled (can be overriden by device configuration)
    interval: 30				# Execute the command every 30 seconds
    command: "fpind {{host}}"   # Command to run
```

You can use variable expansion in the `command` field.
All these variables will be merged with the specific configuration of the device.

Example:

```
---
cpu:                            # Service name
    remote: false               # Local check, will be executed by the agent
    interval: 600               # Execute the command every 5 minutes
	# Command to run. `critical` and `warning` must be defined here or in the device configuration
    command: "check_cpu -c {{critical}} -w {{warning}}"
```

Devices configuration
---------------------

All devices can be organized in group with inheritance, using a regular filesystem tree. By default the root of this tree is `/etc/hukurou/assets` and the first level represent the Datacenter.

Tree example :

```
├── default.yml
├── Dublin
│   ├── database
│   │   └── db.*.dublin.acme.com
│   ├── default.yml
│   └── webserver
│       └── www\d{3}.dublin.acme.com
└── HongKong
    ├── default.yml
    └── nameserver
        └── dns01.hongkong.acme.com
```


If the file is named `default.yml`, it will be use as default value for all devices in this directory and subdirectories.
If the file name is a hostname, it will match only this device.
If the file name is a regex, it will apply to all devices matching the regex. To enable regex expansion, the variable `regex` in the file itself must be true.

Content example:

```
---
regex: true
services:
    cpu:
        warning: 10       # Set specific value used in the `command` expansion
        critical: 20

    fping:
        disabled: true    # Override default configuration
```


Installation
============

A running instance of Redis is required

TODO

API Usage
=========

TODO

References
==========

http://www.slideshare.net/superdupersheep/stop-using-nagios-so-it-can-die-peacefully
https://www.monitoring-plugins.org/
https://egustafson.github.io/monitorama-2015.html
https://speakerdeck.com/obfuscurity/the-state-of-open-source-monitoring

---
THIS IS A DRAFT - NOT PRODUCTION READY
