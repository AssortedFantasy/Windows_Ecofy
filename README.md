# Windows ECOFY

Simple Utility that Sets processes to run with EcoQoS mode in background.
Processes are identified by executable name (ex: `discord.exe`) (case sensitive).

Rescans running processes every 5 minutes.

build with `zig build`

`ecofy.conf`` in the top level directory serves as a simple example of the config file expected.