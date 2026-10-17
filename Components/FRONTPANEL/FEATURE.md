# Extending the FrontPanel_Subsystem

## Discussion
I want to to extend this subsystem to allow for
8 **profiles**.  Each profile consists of:

1. the ON and OFF color values for each RGB LED.  At present, these
are statically configured as red and blue colors, common for each
LED.  With this capability, each LED's colors will be preset to
arbitrary specified values.

2. The map between the physical LED in sequence, and where in the
capture chain that physical LED's state exists.  In this way, we
can easily reconfigure for different LED arrangements for different
displays without rearranging the capture chain configuration.

## Details and requirements

1. The profile number should default to 0 at reset.

2. For profile 0, the default physical to capture chain mapping should
continue to be 1:1 as it is in the present implementation.

3. For profile 0, the default ON and OFF colors should continue to be
the same as it is in the present implementation.

4. A new "ROM File" should be set in the OSD menu to specify a file that
contains 8 profile configurations, each of which is the physical LED map
and the per LED ON and OFF colors.

5. If a profile "ROM file" is specified, then it's content should be used
to initialize all 8 profiles, rather than using the defaults.

6. When a profile is selected and active, it should be possible for
the program running on the Z80 to still be able to modify the physical
map and the ON and OFF colors as is present.  The modifications made
to a specific profile are left in place in the running system when the
profile is changes, so if the previously modified profile is selected
again, that modified profile is still available.

7. There should be a python program that allows the user to easily specify
and produce the profile "ROM file".  It should generate all 8 profiles
with the existing, sensible defaults even if the user didn't specify
all 8 profiles.

8. The python program should allow the physical mapping be specified
individually for each LED, but also have a shorthand alternative for a
simple X by Y sized matrix, with each row or column ordered uniformly
or in a serpentine pattern.  The program should ensure that 256 LEDs
are specified in the configuration, and warn if the geometry doesn't
produce that.

