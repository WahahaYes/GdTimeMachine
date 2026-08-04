Aug 2 at 9:45 PM

We were working on two attribute. Ob 5 (screenshot mode) and some UX improvements that we decided to tackle.

UX is looking good, but there are two remaining enhancements.

First, screenshot mode isn't able to open the scene when pressing record. We shouldn't disable this. Let's preserve the scene picker (only used when we're not in an active recording for this backend) and have the start button start that scene, then immediately launch off screenshot mode. This removes inconsistent behaviors between our backend.

Second, we have our status icon and text in the dropdown, but don't receive any feedback for users that are using the other record button colocated with normal scene launching icons dock. Let's research whether there is a straightforward means to also provide feedback there. One option might be to just unconditionally (so, not wired into the button but into our addon), print an error or warning message to the console alongside the status icons (when appropriate).

For the actual screenshot behavior, we are seeing the folder be created and a manifest be created, but no screenshots recorded. Despite our unit tests suite being green, we aren't able to collect actual screenshot data at all yet.
