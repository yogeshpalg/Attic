// Exposes the APFS snapshot syscalls to Swift. They are declared in the SDK but
// not surfaced by the Darwin module, and listing snapshots is how Attic accounts
// for the space macOS reports as "purgeable" without shelling out to tmutil.
//
// Only the read-only call is used: `fs_snapshot_list`. Creation, deletion,
// renaming, mounting and reverting come along with the header, and nothing in
// the app calls them.

#ifndef AtticBridge_h
#define AtticBridge_h

#include <sys/attr.h>
#include <sys/snapshot.h>

#endif /* AtticBridge_h */
