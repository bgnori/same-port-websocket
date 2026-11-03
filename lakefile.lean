import Lake
open Lake DSL

package «same-port-websocket» where
  version := v!"0.1.0"

lean_lib StdExt

lean_lib StdExtTests

@[test_driver]
lean_exe Tests where
  root := `Tests

@[default_target]
lean_exe wsecho where
  root := `Main
